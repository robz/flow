(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(***********************************************************************)
(* flow ls (list files) command *)
(***********************************************************************)

open CommandUtils
open Utils_js

let spec =
  {
    CommandSpec.name = "ls";
    doc = "Lists files visible to Flow";
    usage =
      Printf.sprintf
        "Usage: %s ls [OPTION]... [FILE]...\n\nLists files visible to Flow\n"
        CommandUtils.exe_name;
    args =
      CommandSpec.ArgSpec.(
        empty
        |> base_flags
        |> ignore_version_flag
        |> strip_root_flag
        |> ignore_flag
        |> include_flag
        |> untyped_flag
        |> declaration_flag
        |> root_flag
        |> json_flags
        |> from_flag
        |> flag "--all" truthy ~doc:"Even list ignored files"
        |> flag
             "--imaginary"
             truthy
             ~doc:
               "Even list non-existent specified files (normally they are silently dropped). Non-existent files are never considered to be libs."
        |> flag
             "--explain"
             truthy
             ~doc:"Output what kind of file each file is and why Flow cares about it"
        |> input_file_flag "ls"
        |> anon "files or dirs" (list_of string)
      );
  }

type file_result =
  | ImplicitlyIncluded
  | ExplicitlyIncluded
  | ImplicitlyIgnored
  | ExplicitlyIgnored of string option
  | ImplicitLib
  | ExplicitLib
  | ConfigFile

let string_of_file_result = function
  | ImplicitlyIncluded -> "ImplicitlyIncluded"
  | ExplicitlyIncluded -> "ExplicitlyIncluded"
  | ImplicitlyIgnored -> "ImplicitlyIgnored"
  | ExplicitlyIgnored _ -> "ExplicitlyIgnored"
  | ImplicitLib -> "ImplicitLib"
  | ExplicitLib -> "ExplicitLib"
  | ConfigFile -> "ConfigFile"

let string_of_file_result_with_padding = function
  | ImplicitlyIncluded -> "ImplicitlyIncluded"
  | ExplicitlyIncluded -> "ExplicitlyIncluded"
  | ImplicitlyIgnored -> "ImplicitlyIgnored "
  | ExplicitlyIgnored _ -> "ExplicitlyIgnored "
  | ImplicitLib -> "ImplicitLib       "
  | ExplicitLib -> "ExplicitLib       "
  | ConfigFile -> "ConfigFile        "

let explain ~flowconfig_name ~root ~options ~libs raw_file =
  let file = raw_file |> File_path.make |> File_path.to_string in
  let root_str = File_path.to_string root in
  let result =
    let (is_ignored, backup) = Files.is_ignored options file in
    if SSet.mem file libs then
      (* This is a lib file *)
      let flowtyped_path = Files.get_flowtyped_path root in
      if String.starts_with ~prefix:(File_path.to_string flowtyped_path) file then
        ImplicitLib
      else
        ExplicitLib
    else if Server_files_js.config_file flowconfig_name root = file then
      ConfigFile
    else if is_ignored then
      ExplicitlyIgnored backup
    else if String.starts_with ~prefix:root_str file then
      ImplicitlyIncluded
    else if Files.is_included options file then
      ExplicitlyIncluded
    else
      ImplicitlyIgnored
  in
  (raw_file, result)

let json_of_files_with_explanations files =
  Hh_json.(
    let properties =
      Base.List.map
        ~f:(fun (file, res) ->
          ( file,
            match res with
            | ExplicitlyIgnored (Some backup) ->
              JSON_Object
                [
                  ("explanation", JSON_String (string_of_file_result res));
                  ("backup", JSON_String backup);
                ]
            | _ -> JSON_Object [("explanation", JSON_String (string_of_file_result res))]
          ))
        files
    in
    JSON_Object properties
  )

let rec iter_get_next ~f get_next =
  match get_next () with
  | [] -> ()
  | result ->
    List.iter f result;
    iter_get_next ~f get_next

let make_options ~flowconfig ~root ~ignore_flag ~include_flag ~untyped_flag ~declaration_flag =
  let includes = CommandUtils.list_of_string_arg include_flag in
  let ignores =
    List.map (fun ignore -> (ignore, None)) (CommandUtils.list_of_string_arg ignore_flag)
  in
  let untyped = CommandUtils.list_of_string_arg untyped_flag in
  let declarations = CommandUtils.list_of_string_arg declaration_flag in
  let libs = [] in
  CommandUtils.file_options
    flowconfig
    ~root
    ~no_flowlib:true
    ~temp_dir:(CommandUtils.get_temp_dir None |> File_path.make)
    ~haste_paths_excludes:
      (Base.List.map
         ~f:(fun f -> f |> Files.expand_project_root_token ~root |> Str.regexp)
         (FlowConfig.haste_paths_excludes flowconfig)
      )
    ~haste_paths_includes:
      (Base.List.map
         ~f:(fun f -> f |> Files.expand_project_root_token ~root |> Str.regexp)
         (FlowConfig.haste_paths_includes flowconfig)
      )
    ~ignores
    ~implicitly_include_root:(FlowConfig.files_implicitly_include_root flowconfig)
    ~includes
    ~libs
    ~untyped
    ~declarations

(* The problem with Files.wanted is that it says yes to everything except ignored files and libs.
 * So implicitly ignored files (like files in another directory) pass the Files.wanted check *)
let wanted ~root ~options all_unordered_libs file =
  Files.wanted ~options ~include_libdef:false all_unordered_libs file
  &&
  let root_str = spf "%s%s" (File_path.to_string root) Filename.dir_sep in
  String.starts_with ~prefix:root_str file || Files.is_included options file

(* Directories will return a closure that returns every file under that
   directory. Individual files will return a closure that returns just that file
*)
let get_ls_files ~root ~all ~options ~all_unordered_libs ~imaginary = function
  | None ->
    Files.make_next_files
      ~sort:true
      ~root
      ~all
      ~subdir:None
      ~options
      ~include_libdef:false
      ~all_unordered_libs
  | Some dir
    when try Sys.is_directory dir with
         | _ -> false ->
    let subdir = Some (File_path.make dir) in
    Files.make_next_files
      ~sort:true
      ~root
      ~all
      ~subdir
      ~options
      ~include_libdef:false
      ~all_unordered_libs
  | Some file ->
    if
      (Sys.file_exists file || imaginary)
      (* Make flow ls never report flowlib files *)
      && (not (Files.is_in_flowlib options file))
      && (all || wanted ~root ~options all_unordered_libs file)
    then
      let file = file |> File_path.make |> File_path.to_string in
      let rec cb =
        ref (fun () ->
            (cb := (fun () -> []));
            [file]
        )
      in
      (fun () -> !cb ())
    else
      fun () ->
    []

(* We have a list of get_next() functions. This combines them into a single
   get_next function *)
let concat_get_next get_nexts =
  let get_nexts = ref get_nexts in
  let rec concat () =
    match !get_nexts with
    | [] -> []
    | get_next :: rest ->
      (match get_next () with
      | [] ->
        get_nexts := rest;
        concat ()
      | ret -> ret)
  in
  concat

(* Append a constant list of files to the get_next function *)
let get_next_append_const get_next const =
  let const = ref const in
  fun () ->
    match get_next () with
    | [] ->
      let ret = !const in
      const := [];
      ret
    | ret -> ret

let main
    base_flags
    ignore_version
    strip_root
    ignore_flag
    include_flag
    untyped_flag
    declaration_flag
    root_flag
    json
    pretty
    all
    imaginary
    reason
    input_file
    root_or_files
    () =
  let files_or_dirs = get_filenames_from_input ~allow_imaginary:true input_file root_or_files in
  let flowconfig_name = base_flags.Base_flags.flowconfig_name in
  let root =
    guess_root
      flowconfig_name
      (match root_flag with
      | Some root -> Some root
      | None ->
        (match files_or_dirs with
        | first_file :: _ ->
          (* If the first_file doesn't exist or if we can't find a .flowconfig, we'll error. If
           * --strip-root is passed, we want the error to contain a relative path. *)
          let first_file =
            if strip_root then
              Files.relative_path (Sys.getcwd ()) first_file
            else
              first_file
          in
          Some first_file
        | _ -> None))
  in
  let flowconfig =
    read_config_or_exit
      ~enforce_warnings:(not ignore_version)
      (Server_files_js.config_file flowconfig_name root)
  in
  let options =
    make_options ~flowconfig ~root ~ignore_flag ~include_flag ~untyped_flag ~declaration_flag
  in
  let (_, libs) = Files.ordered_and_unordered_lib_paths options in
  (* `flow ls` and `flow ls dir` will list out all the flow files. We want to include lib files, so
   * we pass in ~libs:SSet.empty, which means we won't filter out any lib files *)
  let next_files =
    match files_or_dirs with
    | [] -> get_ls_files ~root ~all ~options ~all_unordered_libs:SSet.empty ~imaginary None
    | files_or_dirs ->
      files_or_dirs
      |> Base.List.map ~f:(fun f ->
             get_ls_files ~root ~all ~options ~all_unordered_libs:SSet.empty ~imaginary (Some f)
         )
      |> concat_get_next
  in
  let root_str = spf "%s%s" (File_path.to_string root) Filename.dir_sep in
  let config_file_absolute = Server_files_js.config_file flowconfig_name root in
  let config_file_relative = Files.relative_path root_str config_file_absolute in
  let include_config_file =
    files_or_dirs = []
    || List.exists
         (fun file_or_dir ->
           file_or_dir = config_file_relative || String.starts_with ~prefix:file_or_dir root_str)
         files_or_dirs
  in
  let next_files =
    if include_config_file then
      get_next_append_const next_files [config_file_absolute]
    else
      next_files
  in
  let normalize_filename filename =
    if not strip_root then
      filename
    else
      Files.relative_path root_str filename
  in
  if json || pretty then
    Hh_json.(
      let files = Files.get_all next_files |> SSet.elements in
      let json =
        if reason then
          files
          (* Mapping may cause a stack overflow. To avoid that, we always use rev_map.
           * Since the amount of rev_maps we use is odd, we reverse the list once more
           * at the end *)
          |> List.rev_map (explain ~flowconfig_name ~root ~options ~libs)
          |> List.rev_map (fun (f, r) -> (normalize_filename f, r))
          |> json_of_files_with_explanations
        else
          JSON_Array (List.rev (List.rev_map (fun f -> JSON_String (normalize_filename f)) files))
      in
      print_json_endline ~pretty json
    )
  else
    let f =
      if reason then
        fun filename ->
      let (f, r) = explain ~flowconfig_name ~root ~options ~libs filename in
      Printf.printf "%s    %s\n%!" (string_of_file_result_with_padding r) (normalize_filename f)
      else
        fun filename ->
      Printf.printf "%s\n%!" (normalize_filename filename)
    in
    iter_get_next ~f next_files

let command = CommandSpec.command spec main
