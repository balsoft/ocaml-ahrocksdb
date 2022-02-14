module Ffi = Rocksdb_ffi.M
module Rocks = Ffi.Rocksdb

module Options = Rocksdb_options

open Ctypes

type error = [ `Msg of string ]

let msg s = Error (`Msg s)

type db = {
  config: Options.config;
  db: Rocks.db;
}

module Desc = struct

  let kind = "rocksdb_db"
  type t = db

end
module W = Wrap.Wrap(Desc)
open W

type t = W.t

let close_db t =
  match unwrap t (fun { db; _ } -> Ok (Rocks.close db)) with
  | Ok () ->
    t.valid <- false;
    Ok ()
  | Error _ -> msg "trying to close a database handle already closed"

let with_error_buffer fn =
  let errb = allocate string_opt None in
  let result = fn errb in
  match !@ errb with
  | None -> Ok result
  | Some err -> msg err

let open_db ~config ~name =
  let options = Options.of_config config in
  match with_error_buffer @@ Rocks.open_ options name with
  | Ok db ->
    let t = wrap { db; config; } in
    Gc.finalise (fun t -> on_finalise t (fun { db; _ } -> Rocks.close db)) t;
    Ok t
  | Error e -> Error e

let open_db_read_only ?fail_on_wal:(fail=false) ~config ~name =
  let options = Options.of_config config in
  match with_error_buffer @@ Rocks.open_read_only options name fail with
  | Ok db ->
    let t = wrap { db; config; } in
    Gc.finalise (fun t -> on_finalise t (fun { db; _ } -> Rocks.close db)) t;
    Ok t
  | Error err -> Error err

let open_db_with_ttl ~config ~name ~ttl =
  let options = Options.of_config config in
  match with_error_buffer @@ Rocks.open_with_ttl options name ttl with
  | Ok db ->
    let t = wrap { db; config; } in
    Gc.finalise (fun t -> on_finalise t (fun { db; _ } -> Rocks.close db)) t;
    Ok t
  | Error err -> Error err

let put db write_options ~key ~value =
  let key_len = String.length key in
  let value_len = String.length value in
  unwrap db @@ fun { db; _ } ->
  Rocks.put db write_options (ocaml_string_start key) key_len (ocaml_string_start value) value_len
  |> with_error_buffer

let delete db write_options key =
  let key_len = String.length key in
  unwrap db @@ fun { db; _ } ->
  Rocks.delete db write_options (ocaml_string_start key) key_len
  |> with_error_buffer

let get db read_options key =
  let key_len = String.length key in
  let result_len = allocate Ffi.V.int_to_size_t 0 in
  let result = unwrap db @@ fun { db; _ }  ->
    with_error_buffer @@ Rocks.get db read_options (ocaml_string_start key) key_len result_len
  in
  match result with
  | Error err -> Error err
  | Ok result_ptr ->
    match Ctypes.is_null (to_voidp result_ptr) with
    | true -> Ok `Not_found
    | false ->
      let result = string_from_ptr result_ptr ~length:(!@ result_len) in
      Gc.finalise (fun result_ptr -> Rocks.free (to_voidp result_ptr)) result_ptr;
      Ok (`Found result)

let flush db flush_options =
  unwrap db @@ fun { db; _ } ->
  Rocks.flush db flush_options
  |> with_error_buffer

let compact_now db =
  unwrap db @@ fun { db; _ } ->
  Ok (Rocks.compact_range db None 0 None 0)

let stats db =
  unwrap  db @@ fun { db;  _ } ->
  match Rocks.property_value db "rocksdb.stats" with
  | None -> Ok None
  | Some stats ->
    let string = coerce (ptr char) string stats in
    Gc.finalise (fun stats -> Rocks.free (to_voidp stats)) stats;
    Ok (Some string)

let get_cache_usage db =
  unwrap db @@ fun { config; _ } ->
  match config.block_cache with
  | Some cache -> Ok (Options.Cache.LRU.get_usage cache)
  | None -> msg "get_cache_usage: no cache was set for this database"

module Batch = struct

  open Rocks

  type batch = Batch.t

  let create () =
    let t = Batch.create () in
    Gc.finalise Batch.destroy t;
    t

  let count = Batch.count

  let clear = Batch.clear

  let put batch ~key ~value =
    let key_len = String.length key in
    let value_len = String.length value in
    Batch.put batch (ocaml_string_start key) key_len (ocaml_string_start value) value_len

  let write db write_options batch =
    unwrap db @@ fun { db;  _ } ->
    Rocks.write db write_options batch |> with_error_buffer

  let simple_write_batch db write_options elts =
    let batch = create () in
    List.iter (fun (key, value) -> put batch ~key ~value) elts;
    write db write_options batch

end

module Iterator = struct

  open Rocks

  type iterator = Iterator.t

  let create db read_options =
    unwrap db @@ fun { db; _ } ->
    let t = Iterator.create db read_options in
    Gc.finalise Iterator.destroy t;
    Ok t

  let seek t key =
    let len = String.length key in
    Iterator.seek t (ocaml_string_start key) len

  let next = Iterator.next

  let get_key t =
    let result_len = allocate Ffi.V.int_to_size_t 0 in
    let result = Iterator.key t result_len in
    match Ctypes.is_null (to_voidp result) with
    | true -> raise Not_found
    | false ->
       let result_s = string_from_ptr result ~length:(!@ result_len) in
       result_s

  let get_value t =
    let result_len = allocate Ffi.V.int_to_size_t 0 in
    let result = Iterator.value t result_len in
    match Ctypes.is_null (to_voidp result) with
    | true -> raise Not_found
    | false ->
      let result_s = string_from_ptr result ~length:(!@ result_len) in
      result_s

  let is_valid = Iterator.valid

  let get t =
    if is_valid t then begin
       try
         let key = get_key t in
         let value = get_value t in
         Some (key, value)
       with
       | Not_found -> None
    end
    else None

end

module Perf_context = struct

  type perf_context = Ffi.PerfContext.t
  type counter = Ffi.PerfContext.Counters.t

  module Counters = Ffi.PerfContext.Counters

  let create () =
    let t = Ffi.PerfContext.create () in
    Gc.finalise Ffi.PerfContext.destroy t;
    t

  let reset = Ffi.PerfContext.reset

  let metric = Ffi.PerfContext.metric

end
