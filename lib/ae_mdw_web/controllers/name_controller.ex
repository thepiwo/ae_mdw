defmodule AeMdwWeb.NameController do
  use AeMdwWeb, :controller
  use PhoenixSwagger

  alias AeMdw.Validate
  alias AeMdw.Db.Name
  alias AeMdw.Db.Model
  alias AeMdw.Db.Format
  alias AeMdw.Db.Stream, as: DBS
  alias AeMdw.Error.Input, as: ErrInput
  alias AeMdwWeb.Continuation, as: Cont
  alias AeMdwWeb.SwaggerParameters
  require Model

  import AeMdwWeb.Util
  import AeMdw.{Util, Db.Util}

  ##########

  def stream_plug_hook(%Plug.Conn{path_info: ["names", "owned_by" | _]} = conn),
    do: conn

  def stream_plug_hook(%Plug.Conn{params: params} = conn) do
    alias AeMdwWeb.DataStreamPlug, as: P

    rem = rem_path(conn.path_info)

    P.handle_assign(
      conn,
      (rem == [] && {:ok, {:gen, last_gen()..0}}) || P.parse_scope(rem, ["gen"]),
      P.parse_offset(params),
      {:ok, %{}}
    )
  end

  defp rem_path(["names", x | rem]) when x in ["auctions", "inactive", "active"], do: rem
  defp rem_path(["names" | rem]), do: rem

  ##########

  def auction(conn, %{"id" => ident} = params),
    do:
      handle_input(conn, fn ->
        auction_reply(conn, Validate.plain_name!(ident), expand?(params))
      end)

  def pointers(conn, %{"id" => ident}),
    do: handle_input(conn, fn -> pointers_reply(conn, Validate.plain_name!(ident)) end)

  def pointees(conn, %{"id" => ident}),
    do: handle_input(conn, fn -> pointees_reply(conn, Validate.name_id!(ident)) end)

  def name(conn, %{"id" => ident} = params),
    do:
      handle_input(conn, fn ->
        name_reply(conn, Validate.plain_name!(ident), expand?(params))
      end)

  def owned_by(conn, %{"id" => owner} = params),
    do:
      handle_input(conn, fn ->
        owned_by_reply(conn, Validate.id!(owner, [:account_pubkey]), expand?(params))
      end)

  def auctions(conn, _req),
    do: handle_input(conn, fn -> Cont.response(conn, &json/2) end)

  def inactive_names(conn, _req),
    do: handle_input(conn, fn -> Cont.response(conn, &json/2) end)

  def active_names(conn, _req),
    do: handle_input(conn, fn -> Cont.response(conn, &json/2) end)

  def names(conn, _req),
    do: handle_input(conn, fn -> Cont.response(conn, &json/2) end)

  ##########

  # scope is used here only for identification of the continuation
  def db_stream(:auctions, params, _scope),
    do: do_auctions_stream(validate_params!(params), expand?(params))

  def db_stream(:inactive_names, params, _scope),
    do: do_inactive_names_stream(validate_params!(params), expand?(params))

  def db_stream(:active_names, params, _scope),
    do: do_active_names_stream(validate_params!(params), expand?(params))

  def db_stream(:names, params, _scope),
    do: do_names_stream(validate_params!(params), expand?(params))

  ##########

  def name_reply(conn, plain_name, expand?) do
    with {info, source} <- Name.locate(plain_name) do
      json(conn, Format.to_map(info, source, expand?))
    else
      nil ->
        raise ErrInput.NotFound, value: plain_name
    end
  end

  def pointers_reply(conn, plain_name) do
    with {m_name, Model.ActiveName} <- Name.locate(plain_name) do
      json(conn, Format.map_raw_values(Name.pointers(m_name), &Format.to_json/1))
    else
      {_, Model.InactiveName} ->
        raise ErrInput.Expired, value: plain_name

      _ ->
        raise ErrInput.NotFound, value: plain_name
    end
  end

  def pointees_reply(conn, pubkey) do
    {active, inactive} = Name.pointees(pubkey)

    json(conn, %{
      "active" => Format.map_raw_values(active, &Format.to_json/1),
      "inactive" => Format.map_raw_values(inactive, &Format.to_json/1)
    })
  end

  def auction_reply(conn, plain_name, expand?) do
    map_some(
      Name.locate_bid(plain_name),
      &json(conn, Format.to_map(&1, Model.AuctionBid, expand?))
    ) ||
      raise ErrInput.NotFound, value: plain_name
  end

  def owned_by_reply(conn, owner_pk, expand?) do
    %{actives: actives, top_bids: top_bids} = Name.owned_by(owner_pk)

    jsons = fn plains, source, locator ->
      for plain <- plains, reduce: [] do
        acc ->
          with {info, ^source} <- locator.(plain) do
            [Format.to_map(info, source, expand?) | acc]
          else
            _ -> acc
          end
      end
    end

    actives = jsons.(actives, Model.ActiveName, &Name.locate/1)

    top_bids =
      jsons.(
        top_bids,
        Model.AuctionBid,
        &map_some(Name.locate_bid(&1), fn x -> {x, Model.AuctionBid} end)
      )

    json(conn, %{"active" => actives, "top_bid" => top_bids})
  end

  ##########

  def do_auctions_stream({:name, _} = params, expand?),
    do: DBS.Name.auctions(params, &Format.to_map(&1, Model.AuctionBid, expand?))

  def do_auctions_stream({:expiration, _} = params, expand?) do
    mapper =
      &:mnesia.async_dirty(fn ->
        k = Name.auction_bid_key(&1)
        k && Format.to_map(k, Model.AuctionBid, expand?)
      end)

    DBS.Name.auctions(params, mapper)
  end

  def do_inactive_names_stream({:name, _} = params, expand?),
    do: DBS.Name.inactive_names(params, &Format.to_map(&1, Model.InactiveName, expand?))

  def do_inactive_names_stream({:expiration, _} = params, expand?),
    do: DBS.Name.inactive_names(params, exp_to_formatted_name(Model.InactiveName, expand?))

  def do_active_names_stream({:name, _} = params, expand?),
    do: DBS.Name.active_names(params, &Format.to_map(&1, Model.ActiveName, expand?))

  def do_active_names_stream({:expiration, _} = params, expand?),
    do: DBS.Name.active_names(params, exp_to_formatted_name(Model.ActiveName, expand?))

  def do_names_stream({:name, dir}, expand?) do
    streams = [
      do_inactive_names_stream({:name, dir}, expand?),
      do_active_names_stream({:name, dir}, expand?)
    ]

    merged_stream(streams, & &1["name"], dir)
  end

  def do_names_stream({:expiration, :forward} = params, expand?),
    do:
      Stream.concat(
        do_inactive_names_stream(params, expand?),
        do_active_names_stream(params, expand?)
      )

  def do_names_stream({:expiration, :backward} = params, expand?),
    do:
      Stream.concat(
        do_active_names_stream(params, expand?),
        do_inactive_names_stream(params, expand?)
      )

  ##########

  def validate_params!(params),
    do: do_validate_params!(Map.delete(params, "expand"))

  def do_validate_params!(%{"by" => [what], "direction" => [dir]}) do
    what in ["name", "expiration"] || raise ErrInput.Query, value: "by=#{what}"
    dir in ["forward", "backward"] || raise ErrInput.Query, value: "direction=#{dir}"
    {String.to_atom(what), String.to_atom(dir)}
  end

  def do_validate_params!(%{"by" => [what]}) do
    what in ["name", "expiration"] || raise ErrInput.Query, value: "by=#{what}"
    {String.to_atom(what), :forward}
  end

  def do_validate_params!(params) when map_size(params) > 0 do
    badkey = hd(Map.keys(params))
    raise ErrInput.Query, value: "#{badkey}=#{Map.get(params, badkey)}"
  end

  def do_validate_params!(_params), do: {:expiration, :backward}

  def exp_to_formatted_name(table, expand?) do
    fn {:expiration, {_, plain_name}, _} ->
      case Name.locate(plain_name) do
        {m_name, ^table} -> Format.to_map(m_name, table, expand?)
        _ -> nil
      end
    end
  end

  ##########

  def t() do
    pk =
      <<140, 45, 15, 171, 198, 112, 76, 122, 188, 218, 79, 0, 14, 175, 238, 64, 9, 82, 93, 44,
        169, 176, 237, 27, 115, 221, 101, 211, 5, 168, 169, 235>>

    DBS.map(
      :backward,
      :raw,
      {:or, [["name_claim.account_id": pk], ["name_transfer.recipient_id": pk]]}
    )
  end

  ##########
  def swagger_definitions do
    %{
      Pointers:
        swagger_schema do
          title("Pointers")
          description("Schema for pointers")

          properties do
            account_pubkey(:string, "The account public key")
          end

          example(%{
            account_pubkey: "ak_2cJokSy6YHfoE9zuXMygYPkGb1NkrHsXqRUAAj3Y8jD7LdfnU7"
          })
        end,
      Ownership:
        swagger_schema do
          title("Ownership")
          description("Schema for ownership")

          properties do
            current(:string, "The current owner")
            original(:string, "The original account that claimed the name")
          end

          example(%{
            current: "ak_2rGuHcjycoZgzhAY3Jexo6e1scj3JRCZu2gkrSxGEMf2SktE3A",
            original: "ak_2ruXgsLy9jMwEqsgyQgEsxw8chYDfv2QyBfCsR6qtpQYkektWB"
          })
        end,
      Info:
        swagger_schema do
          title("Info")
          description("Schema for info")

          properties do
            active_from(:integer, "The height from which the name becomes active")
            auction_timeout(:integer, "The auction expiry time", nullable: true)
            claims(:array, "The txs indexes when the name has been claimed")
            expire_height(:integer, "The expiry height")
            ownership(Schema.ref(:Ownership), "The owner/owners of the name")
            pointers(Schema.ref(:Pointers), "The pointers")
            revoke(:integer, "The transaction index when the name is revoked", nullable: true)
            transfers(:array, "The txs indexes when the name has been transferred")
            updates(:array, "The txs indexes when the name has been updated")
          end

          example(%{
            active_from: 307_967,
            auction_timeout: nil,
            claims: [
              15_173_653,
              15_173_471,
              15_173_219,
              15_172_614,
              15_141_698,
              15_141_069,
              15_130_223,
              15_123_418,
              15_111_033,
              15_109_837,
              15_109_343,
              15_109_065,
              15_108_088,
              15_105_072
            ],
            expire_height: 357_967,
            ownership: %{
              current: "ak_sWEHSSG5jKNAXYmJgzHsUXgrd5HajBPRcnn72RJLpZ3h5GFUf",
              original: "ak_sWEHSSG5jKNAXYmJgzHsUXgrd5HajBPRcnn72RJLpZ3h5GFUf"
            },
            pointers: %{},
            revoke: nil,
            transfers: [],
            updates: []
          })
        end,
      InfoAuctions:
        swagger_schema do
          title("Info auctions")
          description("Schema for info auctions")

          properties do
            auction_end(:integer, "The key height when the name auction ends")
            bids(:array, "The bids")
            last_bid(Schema.ref(:TxResponse), "The last bid transaction")
          end

          example(%{
            auction_end: 337_254,
            bids: [
              15_174_500,
              13_420_324,
              12_162_516,
              10_084_545,
              10_062_546,
              7_880_893,
              7_878_252,
              5_961_322,
              5_931_405,
              5_583_812,
              4_801_808
            ],
            last_bid: %{
              block_hash: "mh_AMe7YRgxoc6cCy1iDx2QZxeGb9kkFG9Ukfj8dF7srttr8RfGQ",
              block_height: 307_494,
              hash: "th_27bjCRSBgXkzWcYqjwJ6CHweyXVft3KeM7e1Suv6sm3LiPsdRx",
              micro_index: 19,
              micro_time: 1_598_932_662_983,
              signatures: [
                "sg_W2HJKB5ygvL2X6tcdKx8uP3kd2rFJZhTbDPCt4REG1isqopwXdsRLxxiizB7P8WHbY8tkwRkDR2CjnxQNTdMuyvBw6RqN"
              ],
              tx: %{
                account_id: "ak_e1PYvFVDZAXMiNC7ikkhaQsKpXzYi6XeiWwY6apAT2j4Ujjoo",
                fee: 16_320_000_000_000,
                name: "b.chain",
                name_fee: 1_100_000_000_000_000_000_000,
                name_id: "nm_26sSGSJdjgNW72dGyctY3PPeFuYtAXd8ySEJTpPK5r5fv2i3sW",
                name_salt: 0,
                nonce: 11,
                type: "NameClaimTx",
                version: 2
              },
              tx_index: 15_174_500
            }
          })
        end,
      NameByIdResponse:
        swagger_schema do
          title("Response for name or encoded hash")
          description("Response schema for name or encoded hash")

          properties do
            active(:boolean, "The active status", required: true)
            info(Schema.ref(:Info), "The info", required: true)
            name(:string, "The name", required: true)
            previous(Schema.array(:Info), "The previous owners", required: true)
            status(:string, "The status", required: true)
          end

          example(%{
            active: true,
            info: %{
              active_from: 307_967,
              auction_timeout: nil,
              claims: [
                15_173_653,
                15_173_471,
                15_173_219,
                15_172_614,
                15_141_698,
                15_141_069,
                15_130_223,
                15_123_418,
                15_111_033,
                15_109_837,
                15_109_343,
                15_109_065,
                15_108_088,
                15_105_072
              ],
              expire_height: 357_967,
              ownership: %{
                current: "ak_sWEHSSG5jKNAXYmJgzHsUXgrd5HajBPRcnn72RJLpZ3h5GFUf",
                original: "ak_sWEHSSG5jKNAXYmJgzHsUXgrd5HajBPRcnn72RJLpZ3h5GFUf"
              },
              pointers: %{},
              revoke: nil,
              transfers: [],
              updates: []
            },
            name: "aeternity.chain",
            previous: [
              %{
                active_from: 162_197,
                auction_timeout: nil,
                claims: [4_712_046, 4_711_222, 4_708_228, 4_693_879, 4_693_568, 4_678_533],
                expire_height: 304_439,
                ownership: %{
                  current: "ak_2rGuHcjycoZgzhAY3Jexo6e1scj3JRCZu2gkrSxGEMf2SktE3A",
                  original: "ak_2ruXgsLy9jMwEqsgyQgEsxw8chYDfv2QyBfCsR6qtpQYkektWB"
                },
                pointers: %{
                  account_pubkey: "ak_2cJokSy6YHfoE9zuXMygYPkGb1NkrHsXqRUAAj3Y8jD7LdfnU7"
                },
                revoke: nil,
                transfers: [8_778_162],
                updates: [11_110_443, 10_074_212, 10_074_008, 8_322_927, 7_794_392]
              }
            ],
            status: "name"
          })
        end,
      NameAuctions:
        swagger_schema do
          title("Name auctions")
          description("Schema for name auctions")

          properties do
            active(:boolean, "The name auction status", required: true)
            info(Schema.ref(:InfoAuctions), "The info", required: true)
            name(:string, "The name", required: true)
            previous(Schema.array(:Info), "The previous owners", required: true)
            status(:string, "The name status", required: true)
          end

          example(%{
            active: false,
            info: %{
              auction_end: 337_254,
              bids: [
                15_174_500,
                13_420_324,
                12_162_516,
                10_084_545,
                10_062_546,
                7_880_893,
                7_878_252,
                5_961_322,
                5_931_405,
                5_583_812,
                4_801_808
              ],
              last_bid: %{
                block_hash: "mh_AMe7YRgxoc6cCy1iDx2QZxeGb9kkFG9Ukfj8dF7srttr8RfGQ",
                block_height: 307_494,
                hash: "th_27bjCRSBgXkzWcYqjwJ6CHweyXVft3KeM7e1Suv6sm3LiPsdRx",
                micro_index: 19,
                micro_time: 1_598_932_662_983,
                signatures: [
                  "sg_W2HJKB5ygvL2X6tcdKx8uP3kd2rFJZhTbDPCt4REG1isqopwXdsRLxxiizB7P8WHbY8tkwRkDR2CjnxQNTdMuyvBw6RqN"
                ],
                tx: %{
                  account_id: "ak_e1PYvFVDZAXMiNC7ikkhaQsKpXzYi6XeiWwY6apAT2j4Ujjoo",
                  fee: 16_320_000_000_000,
                  name: "b.chain",
                  name_fee: 1_100_000_000_000_000_000_000,
                  name_id: "nm_26sSGSJdjgNW72dGyctY3PPeFuYtAXd8ySEJTpPK5r5fv2i3sW",
                  name_salt: 0,
                  nonce: 11,
                  type: "NameClaimTx",
                  version: 2
                },
                tx_index: 15_174_500
              }
            },
            name: "b.chain",
            previous: [],
            status: "auction"
          })
        end,
      NamesAuctionsResponse:
        swagger_schema do
          title("Names auctions")
          description("Schema for names auctions")

          properties do
            data(Schema.array(:NameAuctions), "The data for the names", required: true)
            next(:string, "The continuation link", required: true)
          end
        end,
      NamesResponse:
        swagger_schema do
          title("Names")
          description("Response schema for names")

          properties do
            data(Schema.array(:NameByIdResponse), "The data for the names", required: true)
            next(:string, "The continuation link", required: true)
          end

          example(%{
            data: [
              %{
                active: true,
                info: %{
                  active_from: 163_282,
                  auction_timeout: nil,
                  claims: [4_793_600, 4_792_073, 4_780_558, 4_750_560],
                  expire_height: 362_026,
                  ownership: %{
                    current: "ak_25BWMx4An9mmQJNPSwJisiENek3bAGadze31Eetj4K4JJC8VQN",
                    original: "ak_pMwUuWtqDoPxVtyAmWT45JvbCF2pGTmbCMB4U5yQHi37XF9is"
                  },
                  pointers: %{
                    account_pubkey: "ak_25BWMx4An9mmQJNPSwJisiENek3bAGadze31Eetj4K4JJC8VQN"
                  },
                  revoke: nil,
                  transfers: [11_861_568, 11_860_267],
                  updates: [
                    15_509_041,
                    15_472_510,
                    15_436_683,
                    15_399_850,
                    15_363_107,
                    15_327_260,
                    15_292_125,
                    15_255_201,
                    15_218_294,
                    15_182_623,
                    15_145_666,
                    15_106_041,
                    15_103_138,
                    15_102_422,
                    15_034_493,
                    14_998_378,
                    14_962_285,
                    14_926_110,
                    14_889_735,
                    14_853_605,
                    14_816_113,
                    14_780_302,
                    14_734_948,
                    14_697_934,
                    14_660_004,
                    14_622_742,
                    14_585_275,
                    14_549_202,
                    14_512_586,
                    14_475_599,
                    14_433_402,
                    14_395_593,
                    14_359_214,
                    14_322_121,
                    14_275_361,
                    14_237_928,
                    14_197_055,
                    14_158_176,
                    14_118_957,
                    14_083_790,
                    14_047_637,
                    14_007_331,
                    13_968_434,
                    13_929_634,
                    13_888_411,
                    13_852_034,
                    13_729_934,
                    13_692_516,
                    13_655_299,
                    13_621_141,
                    13_585_850,
                    13_549_286,
                    13_517_014,
                    13_478_966,
                    13_119_079,
                    13_119_035,
                    13_119_002,
                    13_118_969,
                    13_118_936,
                    12_758_156,
                    12_758_112,
                    12_432_743,
                    12_432_718,
                    12_432_693,
                    12_432_668,
                    12_432_643,
                    12_077_832,
                    10_477_629,
                    7_255_087,
                    4_831_909
                  ]
                },
                name: "trustwallet.chain",
                previous: [],
                status: "name"
              }
            ],
            next: "names/gen/312032-0?limit=1&page=2"
          })
        end,
      PointersResponse:
        swagger_schema do
          title("Pointers")
          description("Response schema for pointers")

          properties do
            account_pubkey(:string, "The account public key")
          end

          example(%{account_pubkey: "ak_2HNsyfhFYgByVq8rzn7q4hRbijsa8LP1VN192zZwGm1JRYnB5C"})
        end,
      Update:
        swagger_schema do
          title("Update")
          description("Response schema for update")

          properties do
            block_height(:integer, "The block height")
            micro_index(:integer, "The micro block index")
            tx_index(:integer, "The transaction index")
          end

          example(%{block_height: 279_558, micro_index: 51, tx_index: 12_942_695})
        end,
      ActiveInactive:
        swagger_schema do
          title("Active/Inactive")
          description("Schema for active/inactive")

          properties do
            active_from(:integer, "The height when the name become active")
            expire_height(:integer, "The height when the name expire")
            name(:string, "The name")
            update(Schema.ref(:Update), "The update info")
          end

          example(%{
            active_from: 279_555,
            expire_height: 329_558,
            name: "wwwbeaconoidcom.chain",
            update: %{block_height: 279_558, micro_index: 51, tx_index: 12_942_695}
          })
        end,
      ActivesInactives:
        swagger_schema do
          title("Actives/Inactives")
          description("Schema for actives/inactives ")

          properties do
            account_pubkey(Schema.array(:ActiveInactive), "The account info")
          end
        end,
      PointeesResponse:
        swagger_schema do
          title("Pointees")
          description("Response schema for pointees")

          properties do
            active(Schema.ref(:ActivesInactives), "The active info")
            inactive(Schema.ref(:ActivesInactives), "The inactive info")
          end

          example(%{
            active: %{
              account_pubkey: [
                %{
                  active_from: 279_555,
                  expire_height: 329_558,
                  name: "wwwbeaconoidcom.chain",
                  update: %{block_height: 279_558, micro_index: 51, tx_index: 12_942_695}
                }
              ]
            },
            inactive: %{}
          })
        end
    }
  end

  swagger_path :name do
    get("/name/{id}")
    description("Get information for given name or encoded hash")
    produces(["application/json"])
    deprecated(false)
    operation_id("get_name_by_id")
    tag("Middleware")

    parameters do
      id(:path, :string, "The name or encoded hash",
        required: true,
        example: "wwwbeaconoidcom.chain"
      )
    end

    response(200, "Returns information for given name", Schema.ref(:NameByIdResponse))
    response(400, "Bad request", Schema.ref(:ErrorResponse))
  end

  swagger_path :names do
    get("/names")
    description("Get all active and inactive names, except those in auction")
    produces(["application/json"])
    deprecated(false)
    operation_id("get_all_names")
    tag("Middleware")
    SwaggerParameters.by_and_direction_params()
    SwaggerParameters.limit_and_page_params()

    response(200, "Returns information for active and inactive names", Schema.ref(:NamesResponse))
    response(400, "Bad request", Schema.ref(:ErrorResponse))
  end

  swagger_path :active_names do
    get("/names/active")
    description("Get active names.")
    produces(["application/json"])
    deprecated(false)
    operation_id("get_active_names")
    tag("Middleware")
    SwaggerParameters.by_and_direction_params()
    SwaggerParameters.limit_and_page_params()

    response(200, "Returns information for active names", Schema.ref(:NamesResponse))
    response(400, "Bad request", Schema.ref(:ErrorResponse))
  end

  swagger_path :inactive_names do
    get("/names/inactive")
    description("Get all inactive names")
    produces(["application/json"])
    deprecated(false)
    operation_id("get_inactive_names")
    tag("Middleware")
    SwaggerParameters.by_and_direction_params()
    SwaggerParameters.limit_and_page_params()

    response(200, "Returns information for inactive names", Schema.ref(:NamesResponse))
    response(400, "Bad request", Schema.ref(:ErrorResponse))
  end

  swagger_path :auctions do
    get("/names/auctions")
    description("Get all auctions.")
    produces(["application/json"])
    deprecated(false)
    operation_id("get_all_auctions")
    tag("Middleware")
    SwaggerParameters.by_and_direction_params()
    SwaggerParameters.limit_and_page_params()

    response(200, "Returns information for all auctions", Schema.ref(:NamesAuctionsResponse))
    response(400, "Bad request", Schema.ref(:ErrorResponse))
  end

  swagger_path :pointers do
    get("/name/pointers/{id}")
    description("Get pointers for given name")
    produces(["application/json"])
    deprecated(false)
    operation_id("get_pointers_by_id")
    tag("Middleware")

    parameters do
      id(:path, :string, "The name",
        required: true,
        example: "wwwbeaconoidcom.chain"
      )
    end

    response(200, "Returns just pointers for given name", Schema.ref(:PointersResponse))
    response(400, "Bad request", Schema.ref(:ErrorResponse))
  end

  swagger_path :pointees do
    get("/name/pointees/{id}")
    description("Get names pointing to a particular pubkey")
    produces(["application/json"])
    deprecated(false)
    operation_id("get_pointees_by_id")
    tag("Middleware")

    parameters do
      id(:path, :string, "The public key",
        required: true,
        example: "ak_2HNsyfhFYgByVq8rzn7q4hRbijsa8LP1VN192zZwGm1JRYnB5C"
      )
    end

    response(
      200,
      "Returns names pointing to a particular pubkey, partitioned into active and inactive sets",
      Schema.ref(:PointeesResponse)
    )

    response(400, "Bad request", Schema.ref(:ErrorResponse))
  end
end
