import LeanDoc.Genre.Blog.Basic
import LeanDoc.Genre.Blog.Generate
import LeanDoc.Genre.Blog.Highlighted
import LeanDoc.Genre.Blog.HighlightCode
import LeanDoc.Genre.Blog.Site
import LeanDoc.Genre.Blog.Site.Syntax
import LeanDoc.Genre.Blog.Template
import LeanDoc.Genre.Blog.Theme
open LeanDoc.Output Html
open Lean (RBMap)

namespace LeanDoc.Genre.Blog

open Lean Elab
open LeanDoc Doc Elab


@[role_expander htmlSpan]
def htmlSpan : RoleExpander
  | #[.named `«class» (.string classes)], stxs => do
    let args ← stxs.mapM elabInline
    let val ← ``(Inline.other (Blog.InlineExt.htmlSpan $(quote classes)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[directive_expander htmlDiv]
def htmlDiv : DirectiveExpander
  | #[.named `«class» (.string classes)], stxs => do
    let args ← stxs.mapM elabBlock
    let val ← ``(Block.other (Blog.BlockExt.htmlDiv $(quote classes)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[directive_expander blob]
def blob : DirectiveExpander
  | #[.anonymous (.name blobName)], stxs => do
    if h : stxs.size > 0 then logErrorAt stxs[0] "Expected no contents"
    let actualName ← resolveGlobalConstNoOverloadWithInfo blobName
    let val ← ``(Block.other (Blog.BlockExt.blob ($(mkIdentFrom blobName actualName) : Html)) #[])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[role_expander blob]
def inlineBlob : RoleExpander
  | #[.anonymous (.name blobName)], stxs => do
    if h : stxs.size > 0 then logErrorAt stxs[0] "Expected no contents"
    let actualName ← resolveGlobalConstNoOverloadWithInfo blobName
    let val ← ``(Inline.other (Blog.InlineExt.blob ($(mkIdentFrom blobName actualName) : Html)) #[])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[role_expander label]
def label : RoleExpander
  | #[.anonymous (.name l)], stxs => do
    let args ← stxs.mapM elabInline
    let val ← ``(Inline.other (Blog.InlineExt.label $(quote l.getId)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

@[role_expander ref]
def ref : RoleExpander
  | #[.anonymous (.name l)], stxs => do
    let args ← stxs.mapM elabInline
    let val ← ``(Inline.other (Blog.InlineExt.ref $(quote l.getId)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax


@[role_expander page_link]
def page_link : RoleExpander
  | #[.anonymous (.name page)], stxs => do
    let args ← stxs.mapM elabInline
    let pageName := mkIdentFrom page <| docName page.getId
    let val ← ``(Inline.other (Blog.InlineExt.pageref $(quote pageName.getId)) #[ $[ $args ],* ])
    pure #[val]
  | _, _ => throwUnsupportedSyntax

structure ExampleContext where
  contexts : NameMap (Command.State × Parser.ModuleParserState) := {}
deriving Inhabited

initialize exampleContextExt : EnvExtension ExampleContext ← registerEnvExtension (pure {})

structure ExampleMessages where
  messages : NameMap MessageLog := {}
deriving Inhabited

initialize messageContextExt : EnvExtension ExampleMessages ← registerEnvExtension (pure {})

-- FIXME this is a horrid kludge - find a way to systematically rewrite srclocs?
def parserInputString [Monad m] [MonadFileMap m] (str : TSyntax `str) : m String := do
  let preString := (← getFileMap).source.extract 0 (str.raw.getPos?.getD 0)
  let mut code := ""
  let mut iter := preString.iter
  while !iter.atEnd do
    if iter.curr == '\n' then code := code.push '\n'
    else
      for _ in [0:iter.curr.utf8Size.toNat] do
        code := code.push ' '
    iter := iter.next
  code := code ++ str.getString
  return code

structure LeanBlockConfig where
  exampleContext : Ident
  «show» : Option Bool := none
  keep : Option Bool := none
  name : Option Name := none
  error : Option Bool := none

def takeNamed (name : Name) (args : Array RoleArgument) : Array Doc.Elab.RoleArgumentValue × Array RoleArgument := Id.run do
  let mut matching := #[]
  let mut remaining := #[]
  for arg in args do
    if let .named x v := arg then
      if x == name then
        matching := matching.push v
        continue
    remaining := remaining.push arg
  (matching, remaining)

def LeanBlockConfig.fromArgs [Monad m] [MonadInfoTree m] [MonadResolveName m] [MonadEnv m] [MonadError m] (args : Array RoleArgument) : m LeanBlockConfig := do
  if h : 0 < args.size then
    let .anonymous (.name contextName) := args[0]
      | throwError s!"Expected context name, got {repr args[0]}"
    let (showArgs, args) := takeNamed `show <| args.extract 1 args.size
    let showArg ← takeVal `show showArgs >>= Option.mapM (asBool `show)
    let (keepArgs, args) := takeNamed `keep args
    let keepArg ← takeVal `keep keepArgs >>= Option.mapM (asBool `keep)
    let (nameArgs, args) := takeNamed `name args
    let nameArg ← takeVal `keep nameArgs >>= Option.mapM (asName `name)
    let (errorArgs, args) := takeNamed `error args
    let errorArg ← takeVal `error errorArgs >>= Option.mapM (asBool `error)
    if !args.isEmpty then
      throwError s!"Unexpected arguments: {repr args}"
    pure {
      exampleContext := contextName
      «show» := showArg
      keep := keepArg
      name := nameArg
      error := errorArg
    }
  else throwError "No arguments provided, expected at least a context name"

where
  asName (name : Name) (v : Doc.Elab.RoleArgumentValue) : m Name := do
    match v with
    | .name b => do
      pure b.getId
    | other => throwError "Expected Boolean for '{name}', got {repr other}"
  asBool (name : Name) (v : Doc.Elab.RoleArgumentValue) : m Bool := do
    match v with
    | .name b => do
      let b' ← resolveGlobalConstNoOverloadWithInfo b
      if b' == ``true then pure true
      else if b' == ``false then pure false
      else throwErrorAt b "Expected 'true' or 'false'"
    | other => throwError "Expected Boolean for '{name}', got {repr other}"
  takeVal {α} (key : Name) (vals : Array α) : m (Option α) := do
    if vals.size = 0 then pure none
    else if h : vals.size = 1 then
      have : 0 < vals.size := by rw [h]; trivial
      pure (some vals[0])
    else throwError "Duplicate values for '{key}'"

@[code_block_expander leanInit]
def leanInit : CodeBlockExpander
  | args , str => do
    let config ← LeanBlockConfig.fromArgs args
    let context := Parser.mkInputContext (← parserInputString str) (← getFileName)
    let (header, state, msgs) ← Parser.parseHeader context
    for imp in header[1].getArgs do
      logErrorAt imp "Imports not yet supported here"
    let opts := Options.empty -- .setBool `trace.Elab.info true
    if header[0].isNone then -- if the "prelude" option was not set, use the current env
      let commandState := configureCommandState (←getEnv) {}
      modifyEnv <| fun env => exampleContextExt.modifyState env fun s => {s with contexts := s.contexts.insert config.exampleContext.getId (commandState, state)}
    else
      if header[1].getArgs.isEmpty then
        let (env, msgs) ← processHeader header opts msgs context 0
        if msgs.hasErrors then
          for msg in msgs.toList do
            logMessage msg
          liftM (m := IO) (throw <| IO.userError "Errors during import; aborting")
        let commandState := configureCommandState env {}
        modifyEnv <| fun env => exampleContextExt.modifyState env fun s => {s with contexts := s.contexts.insert config.exampleContext.getId (commandState, state)}
    if config.show.getD false then
      pure #[← ``(Block.code none #[] 0 $(quote str.getString))] -- TODO highlighting hack
    else pure #[]
where
  configureCommandState (env : Environment) (msg : MessageLog) : Command.State :=
    { Command.mkState env msg with infoState := { enabled := true } }

open LeanDoc.Genre.Highlighted in
@[code_block_expander lean]
def lean : CodeBlockExpander
  | args, str => do
    let config ← LeanBlockConfig.fromArgs args
    let x := config.exampleContext
    let some (commandState, state) := exampleContextExt.getState (← getEnv) |>.contexts.find? x.getId
      | throwErrorAt x "Can't find example context"
    let context := Parser.mkInputContext (← parserInputString str) (← getFileName)
    -- Process with empty messages to avoid duplicate output
    let s ← IO.processCommands context state { commandState with messages.msgs := {} }
    for t in s.commandState.infoState.trees do
      pushInfoTree t

    match config.error with
    | none =>
      for msg in s.commandState.messages.msgs do
        logMessage msg
    | some true =>
      if s.commandState.messages.hasErrors then
        for msg in s.commandState.messages.errorsToWarnings.msgs do
          logMessage msg
      else
        throwErrorAt str "Error expected in code block, but none occurred"
    | some false =>
      for msg in s.commandState.messages.msgs do
        logMessage msg
      if s.commandState.messages.hasErrors then
        throwErrorAt str "No error expected in code block, one occurred"

    if config.keep.getD true && !(config.error.getD false) then
      modifyEnv fun env => exampleContextExt.modifyState env fun st => {st with contexts := st.contexts.insert x.getId ({s.commandState with messages := {} }, s.parserState)}
    if let some infoName := config.name then
      modifyEnv fun env => messageContextExt.modifyState env fun st => {st with messages := st.messages.insert infoName s.commandState.messages}
    let mut hls := Highlighted.empty
    let infoSt ← getInfoState
    let env ← getEnv
    try
      setInfoState s.commandState.infoState
      setEnv s.commandState.env
      for cmd in s.commands do
        hls := hls ++ (← highlight cmd s.commandState.messages.msgs.toArray)
    finally
      setInfoState infoSt
      setEnv env
    if config.show.getD true then
      pure #[← ``(Block.other (Blog.BlockExt.highlightedCode $(quote x.getId) $(quote hls)) #[Block.code none #[] 0 $(quote str.getString)])]
    else
      pure #[]


private def filterString (p : Char → Bool) (str : String) : String := Id.run <| do
  let mut out := ""
  for c in str.toList do
    if p c then out := out.push c
  pure out

def blogMain (theme : Theme) (site : Site) (options : List String) : IO UInt32 := do
  let hasError ← IO.mkRef false
  let logError msg := do hasError.set true; IO.eprintln msg
  let cfg ← opts {logError := logError} options
  let (site, xref) ← site.traverse cfg
  site.generate theme {site := site, ctxt := ⟨[], cfg⟩, xref := xref, dir := cfg.destination, config := cfg}
  if (← hasError.get) then
    IO.eprintln "Errors were encountered!"
    return 1
  else
    return 0
where
  opts (cfg : Config)
    | ("--output"::dir::more) => opts {cfg with destination := dir} more
    | ("--drafts"::more) => opts {cfg with showDrafts := true} more
    | (other :: _) => throw (↑ s!"Unknown option {other}")
    | [] => pure cfg
