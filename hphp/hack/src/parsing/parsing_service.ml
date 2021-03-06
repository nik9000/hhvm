(**
 * Copyright (c) 2014, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Utils

(*****************************************************************************)
(* Dependencies *)
(*****************************************************************************)

(* Module adding the dependencies related to inheritance.
 * We need a complete accurate graph of dependencies related to inheritance.
 * Because without them, we can't recompute the set of files that must be
 * rechecked when something changes.
 * It is safer for us to add them as soon as possible, that's why we add
 * them just after parsing, because that's as soon as it gets.
 *)
module AddDeps = struct
  module Dep = Typing_deps.Dep
  open Ast

  let rec program defl = List.iter def defl

  and def = function
    | Class c -> class_ c
    | Fun _  | Stmt _  | Typedef _ | Constant _ -> ()
    | Namespace _ | NamespaceUse _ -> assert false

  and class_ c =
    let name = snd c.c_name in
    List.iter (hint name) c.c_extends;
    List.iter (hint name) c.c_implements;
    List.iter (class_def name) c.c_body

  and class_def root = function
    | ClassUse h -> hint root h
    | ClassTraitRequire (_, h) -> hint root h
    | Attributes _  | Const _ | ClassVars _ | Method _-> ()

  and hint root (_, h) =
    match h with
    | Happly ((_, parent), _) ->
        Typing_deps.add_idep (Some (Dep.Class root)) (Dep.Extends parent)
    | Hoption _ | Hfun _ | Htuple _ | Hshape _ -> ()


end


(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let neutral = (SMap.empty, [], SSet.empty, SSet.empty)

let empty_file_info : FileInfo.t = {
  FileInfo.funs = [];
  classes = [];
  types = [];
  consts = [];
  comments = [];
  consider_names_just_for_autoload = false;
}

(* Given a Ast.program, give me the list of entities it defines *)
let get_defs ast =
  List.fold_left begin fun (acc1, acc2, acc3, acc4) def ->
    match def with
    | Ast.Fun f -> f.Ast.f_name :: acc1, acc2, acc3, acc4
    | Ast.Class c -> acc1, c.Ast.c_name :: acc2, acc3, acc4
    | Ast.Typedef t -> acc1, acc2, t.Ast.t_id :: acc3, acc4
    | Ast.Constant cst -> acc1, acc2, acc3, cst.Ast.cst_name :: acc4
    | Ast.Namespace _
    | Ast.NamespaceUse _ -> assert false
     (* toplevel statements are ignored *)
    | Ast.Stmt _ -> acc1, acc2, acc3, acc4
  end ([], [], [], []) ast

let legacy_php_file_info = ref (fun fn ->
  empty_file_info
)

(* Parsing a file without failing
 * acc is a file_info
 * errorl is a list of errors
 * error_files is SSet.t of files that we failed to parse
 *)
let parse (acc, errorl, error_files, php_files) fn =
  let errorl', {Parser_hack.is_hh_file; comments; ast} =
    Errors.do_ begin fun () ->
      Parser_hack.from_file fn
    end
  in
  Parsing_hooks.dispatch_file_parsed_hook fn ast;
  if is_hh_file then begin
    AddDeps.program ast;
    let funs, classes, types, consts = get_defs ast in
    Parser_heap.ParserHeap.add fn ast;
    let defs =
      {FileInfo.funs; classes; types; consts; comments;
       consider_names_just_for_autoload = false}
    in
    let acc = SMap.add fn defs acc in
    let errorl = List.rev_append errorl' errorl in
    let error_files =
      if errorl' = []
      then error_files
      else SSet.add fn error_files
    in
    acc, errorl, error_files, php_files
  end
  else begin
    let info = try !legacy_php_file_info fn with _ -> empty_file_info in
    let acc = SMap.add fn info acc in
    let php_files = SSet.add fn php_files in
    (* we also now keep in the file_info regular php files
     * as we need at least their names in hack build
     *)
    acc, errorl, error_files, php_files
  end

(* Merging the results when the operation is done in parallel *)
let merge_parse
    (acc1, status1, files1, pfiles1)
    (acc2, status2, files2, pfiles2) =
  SMap.fold SMap.add acc1 acc2, List.rev_append status1 status2,
  SSet.union files1 files2,
  SSet.union pfiles1 pfiles2

let parse_files acc fnl =
  List.fold_left parse acc fnl

let parse_parallel workers get_next =
  MultiWorker.call
      workers
      ~job:parse_files
      ~neutral:neutral
      ~merge:merge_parse
      ~next:get_next

(*****************************************************************************)
(* Main entry points *)
(*****************************************************************************)

let go workers ~get_next =
  let fast, errorl, failed_parsing, php_files =
    parse_parallel workers get_next in
  Parsing_hooks.dispatch_parse_task_completed_hook (SMap.keys fast) php_files;
  fast, errorl, failed_parsing
