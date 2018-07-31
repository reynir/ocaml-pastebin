open Result

module Pastes = Store.Make(struct let max = 128 end)

module ECB = Nocrypto.Cipher_block.DES.ECB

let () = ignore @@ Nocrypto_entropy_lwt.initialize ()

let secret = Nocrypto.Rng.generate ECB.key_sizes.(0)
let key = ECB.of_secret secret

let cs_of_int64 n =
  let buf = Cstruct.create 8 in
  let () = Cstruct.BE.set_uint64 buf 0 n in
  buf
  
let int64_of_cs buf =
  Cstruct.BE.get_uint64 buf 0

let re_b64_digit =
  Re.(alt [digit; rg 'a' 'z'; rg 'A'  'Z'; char '/'; char '+'])

let re_b64_num =
  let num_digits = ceil (float_of_int ECB.block_size *. 4. /. 3.) |> int_of_float in
  let padding_size = 3 - (ECB.block_size mod 3) in
  let padding = Re.repn (Re.char '=') padding_size (Some padding_size) in
  Re.seq [Re.repn re_b64_digit num_digits (Some num_digits);
          Re.opt padding]


let tyre_b64_num = Tyre.conv
    (fun x -> B64.decode x |> Cstruct.of_string |> int64_of_cs)
    (fun x -> cs_of_int64 x |> Cstruct.to_string |> B64.encode ~pad:false)
    (Tyre.regex re_b64_num)

let tyre_resource = Tyre.(str "/p/" *> tyre_b64_num)
let tyre_resource_re = Tyre.compile tyre_resource

let callback _conn (req : Cohttp.Request.t) (body : Cohttp_lwt.Body.t)
  : (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t =
  match req.Cohttp.Request.meth with
  | `GET ->
    let resource = req.Cohttp.Request.resource in
    let x = Tyre.exec tyre_resource_re resource in
    begin match x with
      | Ok n -> 
        let idx = cs_of_int64 n
                  |> ECB.decrypt ~key
                  |> int64_of_cs in
        begin match Pastes.get idx with
          | Some s ->
            Lwt.return (Cohttp.Response.make ~headers:(Cohttp.Header.init_with "Content-Type" "text/plain") (),
             Cohttp_lwt.Body.of_string s)
          | None ->
            Lwt.return (Cohttp.Response.make ~status:`Not_found (),
                        Cohttp_lwt.Body.of_string "Not found\n")
        end
      | Error _ ->
        Lwt.return (Cohttp.Response.make ~status:`Bad_request (),
                    Cohttp_lwt.Body.of_string "Bad Request\n")
    end
  | `POST ->
    let%lwt body = Cohttp_lwt.Body.to_string body in
    let idx = Pastes.put body in
    let path = cs_of_int64 idx
              |> ECB.encrypt ~key
              |> int64_of_cs
              |> Tyre.eval tyre_resource in
    let req_url = Cohttp.Request.uri req in
    let url =  Uri.with_scheme (Uri.with_path req_url path) (Some "http") in
    Lwt.return (Cohttp.Response.make ~status:`Created (),
                Cohttp_lwt.Body.of_string (Uri.to_string url ^ "\n"))
  | _ ->
    Lwt.return (Cohttp.Response.make ~status:`Bad_request (),
                Cohttp_lwt.Body.of_string "Bad request\n")

let server =
  Cohttp_lwt_unix.Server.make ~callback ()

let lwt_main src port =
  let%lwt ctx = Conduit_lwt_unix.init ?src () in
  let ctx = Cohttp_lwt_unix.Net.init ~ctx () in
Cohttp_lwt_unix.Server.create ~ctx ~mode:(`TCP (`Port port)) server
