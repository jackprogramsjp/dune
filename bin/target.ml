open Stdune
module Log = Dune_util.Log
module Context = Dune_rules.Context
module Action_builder = Dune_engine.Action_builder
module Build_system = Dune_engine.Build_system
open Memo.Build.O

type t =
  | File of Path.t
  | Alias of Alias.t

type resolve_input =
  | Path of Path.t
  | Dep of Arg.Dep.t

let request targets =
  List.fold_left targets ~init:(Action_builder.return ()) ~f:(fun acc target ->
      let open Action_builder.O in
      acc
      >>>
      match target with
      | File path -> Action_builder.path path
      | Alias { Alias.name; recursive; dir; contexts } ->
        let contexts = List.map ~f:Dune_rules.Context.name contexts in
        (if recursive then
          Build_system.Alias.dep_rec_multi_contexts
        else
          Build_system.Alias.dep_multi_contexts)
          ~dir ~name ~contexts)

let target_hint (_setup : Dune_rules.Main.build_system) path =
  assert (Path.is_managed path);
  let sub_dir = Option.value ~default:path (Path.parent path) in
  let+ candidates = Build_system.all_targets () >>| Path.Build.Set.to_list in
  let candidates =
    if Path.is_in_build_dir path then
      List.map ~f:Path.build candidates
    else
      List.map candidates ~f:(fun path ->
          match Path.Build.extract_build_context path with
          | None -> Path.build path
          | Some (_, path) -> Path.source path)
  in
  let candidates =
    (* Only suggest hints for the basename, otherwise it's slow when there are
       lots of files *)
    List.filter_map candidates ~f:(fun path ->
        if Path.equal (Path.parent_exn path) sub_dir then
          Some (Path.to_string path)
        else
          None)
  in
  let candidates = String.Set.of_list candidates |> String.Set.to_list in
  User_message.did_you_mean (Path.to_string path) ~candidates

let resolve_path path ~(setup : Dune_rules.Main.build_system) =
  let checked = Util.check_path setup.workspace.contexts path in
  let can't_build path =
    let+ hint = target_hint setup path in
    Error hint
  in
  let as_source_dir src =
    if Dune_engine.File_tree.dir_exists src then
      Some
        [ Alias
            (Alias.in_dir ~name:Dune_engine.Alias.Name.default ~recursive:true
               ~contexts:setup.workspace.contexts path)
        ]
    else
      None
  in
  let build () =
    Build_system.is_target path >>= function
    | true -> Memo.Build.return (Ok [ File path ])
    | false -> can't_build path
  in
  match checked with
  | External _ -> Memo.Build.return (Ok [ File path ])
  | In_source_dir src -> (
    match as_source_dir src with
    | Some res -> Memo.Build.return (Ok res)
    | None -> (
      Memo.Build.parallel_map setup.workspace.contexts ~f:(fun ctx ->
          let path =
            Path.append_source (Path.build ctx.Context.build_dir) src
          in
          Build_system.is_target path >>| function
          | true -> Some (File path)
          | false -> None)
      >>| List.filter_map ~f:Fun.id
      >>= function
      | [] -> can't_build path
      | l -> Memo.Build.return (Ok l)))
  | In_build_dir (_ctx, src) -> (
    match as_source_dir src with
    | Some res -> Memo.Build.return (Ok res)
    | None -> build ())
  | In_install_dir _ -> build ()

let expand_path common ~(setup : Dune_rules.Main.build_system) ctx sv =
  let sctx =
    Dune_engine.Context_name.Map.find_exn setup.scontexts (Context.name ctx)
  in
  let dir =
    Path.Build.relative ctx.Context.build_dir
      (String.concat ~sep:Filename.dir_sep (Common.root common).to_cwd)
  in
  let* expander = Dune_rules.Super_context.expander sctx ~dir in
  let expander =
    Dune_rules.Dir_contents.add_sources_to_expander sctx expander
  in
  let+ s, _deps =
    Build_system.For_command_line.eval_build_request
      (Dune_rules.Expander.expand_str expander sv)
  in
  Path.relative Path.root (Common.prefix_target common s)

let resolve_alias common ~recursive sv ~(setup : Dune_rules.Main.build_system) =
  match Dune_engine.String_with_vars.text_only sv with
  | Some s ->
    Ok
      [ Alias
          (Alias.of_string common ~recursive s
             ~contexts:setup.workspace.contexts)
      ]
  | None -> Error [ Pp.text "alias cannot contain variables" ]

let resolve_target common ~setup = function
  | Dune_rules.Dep_conf.Alias sv as dep ->
    Memo.Build.return
      (Result.map_error
         ~f:(fun hints -> (dep, hints))
         (resolve_alias common ~recursive:false sv ~setup))
  | Alias_rec sv as dep ->
    Memo.Build.return
      (Result.map_error
         ~f:(fun hints -> (dep, hints))
         (resolve_alias common ~recursive:true sv ~setup))
  | File sv as dep ->
    let f ctx =
      let* path = expand_path common ~setup ctx sv in
      resolve_path path ~setup
      >>| Result.map_error ~f:(fun hints -> (dep, hints))
    in
    Memo.Build.parallel_map setup.workspace.contexts ~f
    >>| Result.List.concat_map ~f:Fun.id
  | dep -> Memo.Build.return (Error (dep, []))

let resolve_targets_mixed common setup user_targets =
  match user_targets with
  | [] -> Memo.Build.return []
  | _ ->
    let+ targets =
      Memo.Build.parallel_map user_targets ~f:(function
        | Dep d -> resolve_target common ~setup d
        | Path p ->
          resolve_path p ~setup
          >>| Result.map_error ~f:(fun hints ->
                  (Arg.Dep.file (Path.to_string p), hints)))
    in
    let config = Common.config common in
    if config.display = Verbose then
      Log.info
        [ Pp.text "Actual targets:"
        ; Pp.enumerate
            (List.concat_map targets ~f:(function
              | Ok targets -> targets
              | Error _ -> []))
            ~f:(function
              | File p -> Pp.verbatim (Path.to_string_maybe_quoted p)
              | Alias a -> Alias.pp a)
        ];
    targets

let resolve_targets common (setup : Dune_rules.Main.build_system) user_targets =
  List.map ~f:(fun dep -> Dep dep) user_targets
  |> resolve_targets_mixed common setup

let resolve_targets_exn common setup user_targets =
  resolve_targets common setup user_targets
  >>| List.concat_map ~f:(function
        | Error (dep, hints) ->
          User_error.raise
            [ Pp.textf "Don't know how to build %s"
                (Arg.Dep.to_string_maybe_quoted dep)
            ]
            ~hints
        | Ok targets -> targets)
