%% Copyright (c) 2008-2022 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : lfe_shell.erl
%% Author  : Robert Virding
%% Purpose : A simple Lisp Flavoured Erlang shell.

%% We keep three environments: the current environment; the saved
%% environment which contains the environment from before a slurp; and
%% the base environment which contains the predefined shell variables,
%% functions and macros. The base environment is used when we need to
%% revert to an "empty" environment. The save environment is used to
%% store the current environment when we 'slurp' a file which we can
%% revert back to when we do an 'unslurp'.

-module(lfe_shell).

-export([start/0,start/1,server/0,server/1,
         run_script/2,run_script/3,
         run_strings/1,run_strings/2,run_string/1,run_string/2,
         new_state/2,new_state/3,upd_state/3]).

%% The shell commands which generally callable.
-export([c/1,c/2,cd/1,ec/1,ec/2,ep/1,ep/2,epp/1,epp/2,help/0,h/1,h/2,h/3,
         i/0,i/1,i/3,l/1,ls/1,clear/0,m/0,m/1,pid/3,p/1,p/2,pp/1,pp/2,pwd/0,
         q/0,flush/0,regs/0,exit/0]).

-import(orddict, [store/3,find/2]).
-import(lists, [reverse/1,foreach/2]).

-include("lfe.hrl").
-include("lfe_docs.hrl").

%% Coloured strings for the LFE banner, red, green, yellow and blue.
-define(RED(Str), "\e[31m" ++ Str ++ "\e[0m").
-define(GRN(Str), "\e[1;32m" ++ Str ++ "\e[0m").
-define(YLW(Str), "\e[1;33m" ++ Str ++ "\e[0m").
-define(BLU(Str), "\e[1;34m" ++ Str ++ "\e[0m").
-define(BOLD(Str), "\e[1m" ++ Str ++ "\e[0m").

%% -compile([export_all]).

%% Implement our own lists functions to get around stacktrace printing
%% problems.

foldl(F, Accu, [Hd|Tail]) ->
    foldl(F, F(Hd, Accu), Tail);
foldl(F, Accu, []) when is_function(F, 2) -> Accu.

%% Shell state.
-record(state, {curr,save,base,             %Current, save and base env
                slurp=false}).              %Are we slurped?

%% run_script(File, Args) -> {Value,State}.
%% run_string(File, Args, State) -> {Value,State}.

-spec run_script(_, _) -> no_return().
-spec run_script(_, _, _) -> no_return().

run_script(File, Args) ->
    run_script(File, Args, new_state(File, Args)).

run_script(File, Args, St0) ->
    St1 = upd_state(File, Args, St0),
    run_file([File], St1).

%% run_strings(Strings) -> {Value,State}.
%% run_strings(Strings, State) -> {Value,State}.

run_strings(Strings) ->
    run_strings(Strings, new_state("lfe", [])).

run_strings(Strings, St) ->
    lists:foldl(fun (S, St0) ->
                        {_,St1} = run_string(S, St0),
                        St1
                end, St, Strings).

%% run_string(String) -> {Value,State}.
%% run_string(String, State) -> {Value,State}.

run_string(String) ->
    run_string(String, new_state("lfe", [])).

run_string(String, St0) ->
    St1 = upd_state(String, [], St0),
    case read_script_string(String) of
        {ok,Forms} ->
            run_loop([Forms], St1);
        {error,E} ->
            slurp_errors("lfe", [E]),
            {error,St1}
    end.

%% start() -> Pid.
%% start(State) -> Pid.

start() ->
    spawn(fun () -> server() end).

start(St) ->
    spawn(fun () -> server(St) end).

%% server() -> no_return().
%% server(State) -> no_return().

server() ->
    %% Create a default base env of predefined shell variables with
    %% default nil bindings and basic shell macros.
    St = new_state("lfe", []),
    server(St).

server(St) ->
    process_flag(trap_exit, true),              %Must trap exists
    display_banner(),
    %% Set shell io to use LFE expand in edlin, ignore error.
    io:setopts([{expand_fun,fun (B) -> lfe_edlin_expand:expand(B) end}]),
    Eval = start_eval(St),                      %Start an evaluator
    server_loop(Eval, St).                      %Run the loop

server_loop(Eval0, St0) ->
    %% Read the form
    Prompt = prompt(),
    {Ret,Eval1} = read_expression(Prompt, Eval0, St0),
    case Ret of
        {ok,Form} ->
            {Eval2,St1} = shell_eval(Form, Eval1, St0),
            server_loop(Eval2, St1);
        {error,E} ->
            list_errors([E]),
            server_loop(Eval1, St0)
    end.

%% shell_eval(From, Evaluator, State) -> {Evaluator,State}.
%%  Evaluate one shell expression. The evaluator may crash in which
%%  case we restart it and return the pid of the new evaluator.

shell_eval(Form, Eval0, St0) ->
    Eval0 ! {eval_expr,self(),Form},
    receive
        {eval_value,Eval0,_Value,St1} ->
            %% We actually don't use the returned value here.
            {Eval0,St1};
        {eval_error,Eval0,Class} ->
            %% Eval errored out, get the exit signal.
            receive {'EXIT',Eval0,{Reason,Stk}} -> ok end,
            report_exception(Class, Reason, Stk),
            Eval1 = start_eval(St0),
            {Eval1,St0};
        {'EXIT',Eval0,Error} ->
            %% Eval exited or was killed
            report_exception(error, Error, []),
            Eval1 = start_eval(St0),
            {Eval1,St0}
    end.

%% prompt() -> Prompt.

prompt() ->
    %% Don't bother flattening the list, no need.
    case is_alive() of
        true -> lfe_io:format1("~s~s~s", node_prompt());
        false ->
            %% If a user supplied the ~node formatting option but the
            %% node is not actually alive, let's get rid of it
            P1 = user_prompt(),
            P2 = re:replace(P1, "~node", "", [{return, list}]),
            lfe_io:format1("~s", [P2])
    end.

node_prompt () ->
    Prompt = user_prompt(),
    Node = atom_to_list(node()),
    case re:run(Prompt, "~node") of
        nomatch -> ["(", Node, [")", Prompt]];
        _ -> ["", re:replace(Prompt, "~node", Node, [{return, list}]), ""]
    end.

user_prompt () ->
    %% Allow users to set a prompt with the -prompt flag; note that
    %% without the flag the default is "lfe> " and to obtain the
    %% old-style LFE prompt, use -prompt classic.
    case init:get_argument(prompt) of
        {ok, [[]]} -> [""];
        {ok, [["classic"]]} -> ["> "];
        {ok, [P]} -> P;
        _ -> ["lfe> "]
    end.

report_exception(Class, Reason, Stk) ->
    %% Use LFE's simplified version of erlang shell's error
    %% reporting but which LFE prettyprints data.
    Sf = fun ({M,_F,_A}) ->                     %Pre R15
                 %% Don't want to see these in stacktrace.
                 (M == lfe_eval) or (M == ?MODULE);
             ({M,_F,_A,_L}) ->                  %R15 and later
                 %% Don't want to see these in stacktrace.
                 (M == lfe_eval) or (M == ?MODULE)
         end,
    Ff = fun (T, I) -> lfe_io:prettyprint1(T, 15, I, 80) end,
    Cs = lfe_lib:format_exception(Class, Reason, Stk, Sf, Ff, 1),
    io:put_chars("** " ++ Cs),                  %Make it more note worthy
    io:nl().

%% read_expression(Prompt, Evaluator, State) -> {Return,Evaluator}.
%%  Start a reader process and wait for an expression. We are cunning
%%  here and just use the exit reason to pass the expression. We must
%%  also handle the evaluator dying and restart it.

read_expression(Prompt, Eval, St) ->
    Read = fun () ->
                   %% io:put_chars(Prompt),
                   %% Ret = lfe_io:read_line(),
                   Ret = lfe_io:read_line(Prompt),
                   exit(Ret)
           end,
    Rdr = spawn_link(Read),
    read_expression_1(Rdr, Eval, St).

read_expression_1(Rdr, Eval, St) ->
    %% Eval is not doing anything here, so exits from it can only
    %% occur if it was terminated by a signal from another process.
    receive
        {'EXIT',Rdr,Ret} ->
            {Ret,Eval};
        {'EXIT',Eval,{Reason,Stk}} ->
            report_exception(error, Reason, Stk),
            read_expression_1(Rdr, start_eval(St), St);
        {'EXIT',Eval,Reason} ->
            report_exception(exit, Reason, []),
            read_expression_1(Rdr, start_eval(St), St)
    end.

make_banner() ->
    [io_lib:format(
       ?GRN("   ..-~~") ++ ?YLW(".~~_") ++ ?GRN("~~---..") ++ "\n" ++
       ?GRN("  (      ") ++ ?YLW("\\\\") ++ ?GRN("     )") ++ "    |   A Lisp-2+ on the Erlang VM\n" ++
       ?GRN("  |`-.._") ++ ?YLW("/") ++ ?GRN("_") ++ ?YLW("\\\\") ++ ?GRN("_.-':") ++ "    |   Type " ++ ?GRN("(help)") ++ " for usage info.\n" ++
       ?GRN("  |         ") ++ ?RED("g") ++ ?GRN(" |_ \\") ++  "   |\n" ++
       ?GRN("  |        ") ++ ?RED("n") ++ ?GRN("    | |") ++   "  |   Docs: " ++ ?BLU("http://docs.lfe.io/") ++ "\n" ++
       ?GRN("  |       ") ++ ?RED("a") ++ ?GRN("    / /") ++   "   |   Source: " ++ ?BLU("http://github.com/lfe/lfe") ++ "\n" ++
       ?GRN("   \\     ") ++ ?RED("l") ++ ?GRN("    |_/") ++  "    |\n" ++
       ?GRN("    \\   ") ++ ?RED("r") ++ ?GRN("     /") ++  "      |   LFE v~s ~s\n" ++
       ?GRN("     `-") ++ ?RED("E") ++ ?GRN("___.-'") ++ "\n\n", [get_lfe_version(), get_abort_message()])].

display_banner() ->
    %% When LFE is called with -noshell, we want to skip the banner. Also, there may be
    %% circumstances where the shell is desired, but the banner needs to be disabled,
    %% thus we want to support both use cases.
    case init:get_argument(noshell) of
        error -> case init:get_argument(nobanner) of
                    error -> io:put_chars(make_banner());
                    _ -> false
                 end;
        _ -> false
    end.

get_abort_message() ->
    %% We can update this later to check for env variable settings for
    %% shells that require a different control character to abort, such
    %% as jlfe.
    "(abort with ^G)".

get_lfe_version() ->
    {ok, [App]} = file:consult(code:where_is_file("lfe.app")),
    proplists:get_value(vsn, element(3, App)).

%% new_state(ScriptName, Args [,Env]) -> State.
%%  Generate a new shell state with all the default functions, macros
%%  and variables.

new_state(Script, Args) ->
    new_state(Script, Args, lfe_env:new()).

new_state(Script, Args, Env0) ->
    Env1 = lfe_env:add_vbinding('script-name', Script, Env0),
    Env2 = lfe_env:add_vbinding('script-args', Args, Env1),
    Base0 = add_shell_functions(Env2),
    Base1 = add_shell_macros(Base0),
    Base2 = add_shell_vars(Base1),
    #state{curr=Base2,save=Base2,base=Base2,slurp=false}.

upd_state(Script, Args, #state{curr=Curr,save=Save,base=Base}=St) ->
    %% Update an environment with with script name and args.
    Upd = fun (E0) ->
                  E1 = lfe_env:add_vbinding('script-name', Script, E0),
                  lfe_env:add_vbinding('script-args', Args, E1)
          end,
    St#state{curr=Upd(Curr),save=Upd(Save),base=Upd(Base)}.

add_shell_vars(Env0) ->
    %% Add default shell expression variables.
    Env1 = foldl(fun (Symb, E) -> lfe_env:add_vbinding(Symb, [], E) end, Env0,
                 ['+','++','+++','-','*','**','***']),
    lfe_env:add_vbinding('$ENV', Env1, Env1).   %This gets it all

update_shell_vars(Form, Value, Env0) ->
    Env1 = foldl(fun ({Symb,Val}, E) -> lfe_env:add_vbinding(Symb, Val, E) end,
                 Env0,
                 [{'+++',lfe_env:fetch_vbinding('++', Env0)},
                  {'++',lfe_env:fetch_vbinding('+', Env0)},
                  {'+',Form},
                  {'***',lfe_env:fetch_vbinding('**', Env0)},
                  {'**',lfe_env:fetch_vbinding('*', Env0)},
                  {'*',Value}]),
    %% Be cunning with $ENV, remove self references so it doesn't grow
    %% indefinitely.
    Env2 = lfe_env:del_vbinding('$ENV', Env1),
    lfe_env:add_vbinding('$ENV', Env2, Env2).

add_shell_functions(Env0) ->
    Fs = [
          {cd,1,[lambda,[d],[':',lfe_shell,cd,d]]},
          {ep,1,[lambda,[e],[':',lfe_shell,ep,e]]},
          {ep,2,[lambda,[e,d],[':',lfe_shell,ep,e,d]]},
          {epp,1,[lambda,[e],[':',lfe_shell,epp,e]]},
          {epp,2,[lambda,[e,d],[':',lfe_shell,epp,e,d]]},
          {h,0,[lambda,[],[':',lfe_shell,help]]},
          {h,1,[lambda,[m], [':',lfe_shell,h,m]]},
          {h,2,[lambda,[m,f], [':',lfe_shell,h,m,f]]},
          {h,3,[lambda,[m,f,a], [':',lfe_shell,h,m,f,a]]},
          {help,0,[lambda,[],[':',lfe_shell,help]]},
          {i,0,[lambda,[],[':',lfe_shell,i]]},
          {i,1,[lambda,[ps],[':',lfe_shell,i,ps]]},
          {i,3,[lambda,[x,y,z],[':',lfe_shell,i,x,y,z]]},
          {clear,0,[lambda,[],[':',lfe_shell,clear]]},
          {pid,3,[lambda,[i,j,k],[':',lfe_shell,pid,i,j,k]]},
          {p,1,[lambda,[e],[':',lfe_shell,p,e]]},
          {p,2,[lambda,[e,d],[':',lfe_shell,p,e,d]]},
          {pp,1,[lambda,[e],[':',lfe_shell,pp,e]]},
          {pp,2,[lambda,[e,d],[':',lfe_shell,pp,e,d]]},
          {pwd,0,[lambda,[],[':',lfe_shell,pwd]]},
          {q,0,[lambda,[],[':',lfe_shell,exit]]},
          {flush,0,[lambda,[],[':',lfe_shell,flush]]},
          {regs,0,[lambda,[],[':',lfe_shell,regs]]},
          {exit,0,[lambda,[],[':',lfe_shell,exit]]}
         ],
    %% Any errors here will crash shell startup!
    Add = fun ({N,Ar,Def}, E) ->
                  lfe_eval:add_dynamic_func(N, Ar, Def, E)
          end,
    Env1 = foldl(Add, Env0, Fs),
    Env1.

%% Last clause in match-lambda macro to catch-all as undefined function.
-define(UNDEF_MATCH_FUNC(Name),
        [[args,'ENV'],?BQ([error,{undefined_func,{Name,?C([length,args])}}])]).

add_shell_macros(Env0) ->
    %% We KNOW how macros are expanded and write them directly in
    %% expanded form here.
    Ms = [{c,[lambda,[args,'$ENV'],?BQ([':',lfe_shell,c,?C_A(args)])]},
          {describe,['match-lambda',
                     [[[list,mod],'$ENV'],?BQ([':',lfe_shell,doc,?Q(?C(mod))])],
                     ?UNDEF_MATCH_FUNC(describe)]},
          {doc,['match-lambda',
                [[[list,mod],'$ENV'],?BQ([':',lfe_shell,h,?Q(?C(mod))])],
                [[[list,mod,func],'$ENV'],
                 ?BQ([':',lfe_shell,h,?Q(?C(mod)),?Q(?C(func))])],
                [[[list,mod,func,arity],'$ENV'],
                 ?BQ([':',lfe_shell,h,?Q(?C(mod)),?Q(?C(func)),?Q(?C(arity))])],
                ?UNDEF_MATCH_FUNC(doc)]},
          {ec,[lambda,[args,'$ENV'],?BQ([':',lfe_shell,ec,?C_A(args)])]},
          {l,[lambda,[args,'$ENV'],?BQ([':',lfe_shell,l,[list|?C(args)]])]},
          {ls,[lambda,[args,'$ENV'],?BQ([':',lfe_shell,ls,[list|?C(args)]])]},
          {m,['match-lambda',
              [[[],'$ENV'],?BQ([':',lfe_shell,m])],
              [[ms,'$ENV'],?BQ([':',lfe_shell,m,[list|?C(ms)]])]]}
         ],
    %% Any errors here will crash shell startup!
    Env1 = lfe_env:add_mbindings(Ms, Env0),
    %% io:fwrite("asm: ~p\n", [Env1]),
    Env1.

%% start_eval(State) -> Evaluator.
%%  Start an evaluator process.

start_eval(St) ->
    Self = self(),
    spawn_link(fun () -> eval_init(Self, St) end).

eval_init(Shell, St) ->
    eval_loop(Shell, St).

eval_loop(Shell, St0) ->
    receive
        {eval_expr,Shell,Form} ->
            St1 = eval_form(Form, Shell, St0),
            eval_loop(Shell, St1)
    end.

%% eval_form(Form, ShellPid, State) -> State.
%%  Evaluate a form, print is reurn value and send updated state back
%%  to the shell manager process. Unfortunately we can't just let it
%%  crash as an error here causes the emulator to generate an error
%%  report. Being cunning and building our own error return value and
%%  doing exit on it seem to fix the problem.

eval_form(Form, Shell, St0) ->
    try
        Ce1 = lfe_env:add_vbinding('-', Form, St0#state.curr),
        %% Macro expand and evaluate it.
        {Value,St1} = eval_form(Form, St0#state{curr=Ce1}),
        %% Print the result, but only to depth 30.
        VS = lfe_io:prettyprint1(Value, 30),
        io:requests([{put_chars,unicode,VS},nl]),
        %% Update bindings.
        Ce2 = update_shell_vars(Form, Value, St1#state.curr),
        St2 = St1#state{curr=Ce2},
        %% Return value and updated state.
        Shell ! {eval_value,self(),Value,St2},
        St2
    catch
        exit:normal -> exit(normal);
        ?CATCH(Class, Reason, Stack)
            %% We don't want the ERROR REPORT generated by the
            %% emulator. Note: exit(kill) needs nothing special.
            Shell ! {eval_error,self(),Class},
            E = nocatch(Class, {Reason,Stack}),
            exit(E)
    end.

nocatch(throw, {Term,Stack}) ->
    {{nocatch,Term},Stack};
nocatch(_, Reason) -> Reason.

%% eval_form(Form, State) -> {Value,State}.
%%  Macro expand the the top form then treat special case top-level
%%  forms.

eval_form(Form, #state{curr=Ce}=St) ->
    %% Flatten progn nested forms.
    %% Don't deep expand, keep everything.
    case lfe_macro:expand_fileforms([{Form,1}], Ce, false, true) of
        {ok,Eforms,Ce1,Ws} ->
            list_warnings(Ws),
            St1 = St#state{curr=Ce1},
            foldl(fun ({F,_}, {_,S}) -> eval_form_1(F, S) end,
                  {[],St1}, Eforms);
        {error,Es,Ws} ->
            list_errors(Es),
            list_warnings(Ws),
            {error,St}
    end.

eval_form_1([progn|Eforms], St) ->              %Top-level nested progn
    foldl(fun (F, {_,S}) -> eval_form_1(F, S) end,
          {[],St}, Eforms);
eval_form_1([set|Rest], St0) ->
    {Value,St1} = set(Rest, St0),
    {Value,St1};
eval_form_1([slurp|Args], St0) ->               %Slurp in a file
    {Value,St1} = slurp(Args, St0),
    {Value,St1};
eval_form_1([unslurp|_], St) ->
    %% Forget everything back to before current slurp.
    unslurp(St);
eval_form_1([run|Args], St0) ->
    {Value,St1} = run_file(Args, St0),
    {Value,St1};
eval_form_1(['reset-environment'], #state{base=Be}=St) ->
    {ok,St#state{curr=Be}};
eval_form_1(['extend-module'|_], St) ->         %Maybe from macro expansion
    {[],St};
eval_form_1(['eval-when-compile'|_], St) ->     %Maybe from macro expansion
    %% We can happily ignore this.
    {[],St};
eval_form_1(['define-record',Name,Fields], #state{curr=Ce0}=St) ->
    %% Don't fully expand the record definition, push it till its used
    %% in the same way as function and macro definitions.
    Ce1 = lfe_env:add_record(Name, Fields, Ce0),
    {Name,St#state{curr=Ce1}};
eval_form_1(['define-function',Name,_Meta,Def], #state{curr=Ce0}=St) ->
    Ar = function_arity(Def),
    Ce1 = lfe_eval:add_dynamic_func(Name, Ar, Def, Ce0),
    {Name,St#state{curr=Ce1}};
eval_form_1(['define-macro',Name,_Meta,Def], #state{curr=Ce0}=St) ->
    Ce1 = lfe_env:add_mbinding(Name, Def, Ce0),
    {Name,St#state{curr=Ce1}};
eval_form_1(Expr, St) ->
    %% General case just evaluate the expression.
    {lfe_eval:expr(Expr, St#state.curr),St}.

function_arity([lambda,As|_]) ->
    length(As);
function_arity(['match-lambda',[Pats|_]|_]) ->
    length(Pats).

list_errors(Es) -> list_ews("~w: ~s\n", Es).

list_warnings(Ws) -> list_ews("~w: Warning: ~s\n", Ws).

list_ews(Format, Ews) ->
    foreach(fun ({L,M,E}) ->
                    Cs = M:format_error(E),
                    lfe_io:format(Format, [L,Cs])
            end, Ews).

%% set(Args, State) -> {Result,State}.

set([], St) -> {[],St};
set([Pat|Rest], #state{curr=Ce}=St) ->
    Epat = lfe_macro:expand_expr_all(Pat, Ce),  %Expand macros in pattern
    set_1(Epat, Rest, St).

set_1(Pat, [['when'|_]=G,Exp], St) ->
    set_1(Pat, [G], Exp, St);                   %Just the guard
set_1(Pat, [Exp], St) ->
    set_1(Pat, [], Exp, St);                    %Empty guard body
set_1(_, _, _) -> erlang:error({bad_form,'set'}).

set_1(Pat, Guard, Exp, #state{curr=Ce0}=St) ->
    Val = lfe_eval:expr(Exp, Ce0),              %Evaluate expression
    case lfe_eval:match_when(Pat, Val, Guard, Ce0) of
        {yes,_,Bs} ->
            Ce1 = foldl(fun ({N,V}, E) -> lfe_env:add_vbinding(N, V, E) end,
                        Ce0, Bs),
            {Val,St#state{curr=Ce1}};
        no -> erlang:error({badmatch,Val})
    end.

%% unslurp(State) -> {ok,State}.
%% slurp(File, State) -> {{ok,Mod},State}.
%%  Load in a file making all the functions and macros available.
%%  There is a bit of trickery to get hold of the compile environment
%%  to get hold of the macros. We call the compiler directly but don't
%%  make the LFE-EXPAND-EXPORTED-MACRO/3 function.

-record(slurp, {mod,funs=[],imps=[]}).          %For slurping

unslurp(St0) ->
    St1 = case St0#state.slurp of
              true ->                           %Roll-back slurp
                  Se = St0#state.save,
                  St0#state{save=none,curr=Se,slurp=false};
              false -> St0                      %Do nothing
          end,
    {ok,St1}.

slurp([File], St0) ->
    {ok,#state{curr=Ce0}=St1} = unslurp(St0),   %Reset the environment
    Name = lfe_eval:expr(File, Ce0),            %Get file name
    case slurp_1(Name, Ce0) of
        {ok,Mod,Ce1} ->                         %Set the new environment
            {{ok,Mod},St1#state{save=Ce0,curr=Ce1,slurp=true}};
        error ->
            {error,St1}
    end.

slurp_1(Name, Ce) ->
    case slurp_file(Name) of
        {ok,Mod,Fs,Env0,Ws} ->
            slurp_warnings(Ws),
            %% Collect functions and imports.
            Sl0 = #slurp{mod=Mod,funs=[],imps=[]},
            Sl1 = lists:foldl(fun collect_module/2, Sl0, Fs),
            %% Add imports to environment.
            Ifun = fun ({M,Is}, Env) ->
                           foldl(fun ({{F,A},R}, E) ->
                                         lfe_env:add_ibinding(M, F, A, R, E)
                                 end, Env, Is)
                   end,
            Env1 = foldl(Ifun, Env0, Sl1#slurp.imps),
            %% Add functions to environment.
            Env2 = foldl(fun ({N,Ar,Def}, Env) ->
                                 lfe_eval:add_dynamic_func(N, Ar, Def, Env)
                         end, Env1, Sl1#slurp.funs),
            {ok,Mod,lfe_env:add_env(Env2, Ce)};
        {error,Mews,Es,Ws} ->
            slurp_errors(Es),
            slurp_warnings(Ws),
            %% Now the errors and warnings for each module.
            foreach(fun ({error,Mes,Mws}) ->
                            slurp_errors(Mes),
                            slurp_warnings(Mws)
                    end, Mews),
            error
    end.

slurp_file(Name) ->
    case lfe_comp:file(Name, [binary,to_split,return]) of
        {ok,[{ok,Mod,Fs0,_}|_],Ws} ->           %Only do first module
            %% Deep expand, don't keep everything.
            case lfe_macro:expand_fileforms(Fs0, lfe_env:new(), true, false) of
                {ok,Fs1,Env,_} ->
                    %% Flatten and trim away any eval-when-compile.
                    {Fs2,42} = lfe_lib:proc_forms(fun slurp_form/3, Fs1, 42),
                    case lfe_lint:module(Fs2) of
                        {ok,_,Lws} -> {ok,Mod,Fs2,Env,Ws ++ Lws};
                        {error,Les,Lws} ->
                            slurp_error_ret(Name, Les, Ws ++ Lws)
                    end;
                {error,Ees,Ews} ->
                    slurp_error_ret(Name, Ees, Ws ++ Ews)
            end;
        Error -> Error
    end.

slurp_error_ret(Name, Es, Ws) ->
    {error,[],[{Name,Es}],[{Name,Ws}]}.

slurp_form(['eval-when-compile'|_], _, D) -> {[],D};
slurp_form(F, L, D) -> {[{F,L}],D}.

collect_module({['define-module',Mod,Meta,Atts],_}, Sl0) ->
    Sl1 = collect_meta(Meta, Sl0),
    Sl2 = collect_attrs(Atts, Sl1),
    Sl2#slurp{mod=Mod};
collect_module({['extend-module',Meta,Atts],_}, Sl0) ->
    Sl1 = collect_meta(Meta, Sl0),
    collect_attrs(Atts, Sl1);
collect_module({['define-function',F,_Meta,Def],_}, #slurp{funs=Fs}=Sl) ->
    Ar = function_arity(Def),
    Sl#slurp{funs=[{F,Ar,Def}|Fs]};
collect_module({_,_}, Sl) ->
    %% Ignore other forms, type and spec defs.
    Sl.

collect_meta(_, St) -> St.

collect_attrs([[import|Is]|Atts], St) ->
    collect_attrs(Atts, collect_imps(Is, St));
collect_attrs([_|Atts], St) ->                  %Ignore everything else
    collect_attrs(Atts, St);
collect_attrs([], St) -> St.

collect_imps(Is, St) ->
    foldl(fun (I, S) -> collect_imp(I, S) end, St, Is).

collect_imp(['from',Mod|Fs], St) ->
    collect_imp(fun ([F,A], Imps) -> store({F,A}, F, Imps) end,
                Mod, St, Fs);
collect_imp(['rename',Mod|Rs], St) ->
    collect_imp(fun ([[F,A],R], Imps) -> store({F,A}, R, Imps) end,
                Mod, St, Rs);
collect_imp(_, St) -> St.                       %Ignore everything else

collect_imp(Fun, Mod, St, Fs) ->
    Imps0 = safe_fetch(Mod, St#slurp.imps, []),
    Imps1 = foldl(Fun, Imps0, Fs),
    St#slurp{imps=store(Mod, Imps1, St#slurp.imps)}.

%% slurp_errors([File, ]Errors) -> ok.
%% slurp_warnings([File, ]Warnings) -> ok.
%%  Print errors and warnings.

slurp_errors(Errors) ->
    foreach(fun ({File,Es}) -> slurp_errors(File, Es) end, Errors).

slurp_errors(File, Es) -> slurp_ews(File, "~s:~w: ~s\n", Es).

slurp_warnings(Warnings) ->
    foreach(fun ({File,Ws}) -> slurp_warnings(File, Ws) end, Warnings).

slurp_warnings(File, Es) -> slurp_ews(File, "~s:~w: Warning: ~s\n", Es).

slurp_ews(File, Format, Ews) ->
    foreach(fun ({Line,Mod,Error}) ->
                    Cs = Mod:format_error(Error),
                    lfe_io:format(Format, [File,Line,Cs])
            end, Ews).

%% run_file(Args, State) -> {Value,State}.
%%  Run the shell expressions in a file. Abort on errors and only
%%  return updated state if there are no errors.

run_file([File], #state{curr=Ce}=St) ->
    Name = lfe_eval:expr(File, Ce),             %Get file name
    case read_script_file(Name) of              %Read the file
        {ok,Forms} ->
            run_loop(Forms, St);
        {error,E} ->
            slurp_errors(Name, [E]),
            {error,St}
    end.

%% read_script_file(FileName) -> {ok,[Sexpr]} | {error,Error}.
%%  Read a file returning the sexprs. Almost the same as
%%  lfe_io:read_file except the we skip the first line if it is a
%%  script line "#! ... ".

read_script_file(File) ->
    case file:open(File, [read]) of
        {ok,Fd} ->
            %% Check if first a script line, if so skip it.
            case io:get_line(Fd, '') of
                "#!" ++ _ ->
                    lfe_io:read_file(Fd, 2);
                _ -> 
                    file:position(Fd, bof),    %Reset to start of file
                    lfe_io:read_file(Fd, 1)
            end
    end.

%% read_script_string(FileName) -> {ok,[Sexpr]} | {error,Error}.
%%  Read a file returning the sexprs. Almost the same as
%%  lfe_io:read_string except parse all forms.

read_script_string(String) ->
    lfe_io:read_string(String).

%% run_loop(Forms, State) -> {Value,State}.
%% run_loop(Forms PrevValue, State) -> {Value,State}.

run_loop(Fs, St) -> run_loop(Fs, [], St).

run_loop([F|Fs], _, St0) ->
    Ce1 = lfe_env:add_vbinding('-', F, St0#state.curr),
    {Value,St1} = eval_form(F, St0#state{curr=Ce1}),
    Ce2 = update_shell_vars(F, Value, St1#state.curr),
    run_loop(Fs, Value, St1#state{curr=Ce2});
run_loop([], Value, St) -> {Value,St}.

%% safe_fetch(Key, Dict, Default) -> Value.

safe_fetch(Key, D, Def) ->
    case find(Key, D) of
        {ok,Val} -> Val;
        error -> Def
    end.

%% The LFE shell command functions.
%%  These are callable from outside the shell as well.

%% c(File [,Args]) -> {ok,Module} | error.
%%  Compile and load an LFE file.

c(File) -> c(File, []).

c(File, Opts0) ->
    Opts1 = [report,verbose|Opts0],             %Always report verbosely
    case lfe_comp:file(File, Opts1) of
        Ok when element(1, Ok) =:= ok ->        %Compilation successful
            Return = lists:member(return, Opts1),
            Binary = lists:member(binary, Opts1),
            OutDir = outdir(Opts1),
            load_files(Ok, Return, Binary, OutDir);
        Error -> Error
    end.

load_files(Ok, _, true, _) -> Ok;               %Binary output
load_files(Ok, Ret, _, Out) ->                  %Beam files created.
    Mods = element(2, Ok),
    lists:map(fun (M) -> load_file(M, Ret, Out) end, Mods).

load_file(Ok, _, Out) ->
    case element(2, Ok) of
        [] -> Ok;                               %No module file to load
        Mod ->                                  %We have a module name
            Bfile = filename:join(Out, atom_to_list(Mod)),
            code:purge(Mod),
            code:load_abs(Bfile, Mod)           %Undocumented
    end.

outdir([{outdir,Dir}|_]) -> Dir;                %Erlang way
outdir([[outdir,Dir]|_]) -> Dir;                %LFE way
outdir([_|Opts]) -> outdir(Opts);
outdir([]) -> ".".

%% cd(Dir) -> ok.

cd(Dir) -> c:cd(Dir).

%% ec(File [,Args]) -> Res.
%%  Compile and load an Erlang file.

ec(F) -> c:c(F).

ec(F, Os) -> c:c(F, Os).

%% ep(Expr [, Depth]) -> ok.
%% epp(Expr [, Depth]) -> ok.
%%  Print/prettyprint a value in Erlang format.

ep(E) ->
    Cs = io_lib:write(E),
    io:put_chars([Cs,$\n]).

ep(E, D) ->
    Cs = io_lib:write(E, D),
    io:put_chars([Cs,$\n]).

epp(E) ->
    Cs = io_lib:format("~p", [E]),
    io:put_chars([Cs,$\n]).

epp(E, D) ->
    Cs = io_lib:format("~P", [E,D]),
    io:put_chars([Cs,$\n]).

%% help() -> ok.

help() ->
    io:put_chars(<<"\nLFE shell built-in functions\n\n"
                   "(c file)       -- compile and load code in <file>\n"
                   "(cd dir)       -- change working directory to <dir>\n"
                   "(clear)        -- clear the REPL output\n"
                   "(doc mod)      -- documentation of a module\n"
                   "(doc mod:mac)  -- documentation of a macro\n"
                   "(doc m:f/a)    -- documentation of a function\n"
                   "(ec file)      -- compile and load code in erlang <file>\n"
                   "(ep expr)      -- print a term in erlang form\n"
                   "(epp expr)     -- pretty print a term in erlang form\n"
                   "(exit)         -- quit - an alias for (q)\n"
                   "(flush)        -- flush any messages sent to the shell\n"
                   "(h)            -- an alias for (help)\n"
                   "(h m)          -- help about module\n"
                   "(h m m)        -- help about function and macro in module\n"
                   "(h m f a)      -- help about function/arity in module\n"
                   "(help)         -- help info\n"
                   "(i)            -- information about the system\n"
                   "(i pids)       -- information about a list of pids\n"
                   "(i x y z)      -- information about pid #Pid<x.y.z>\n"
                   "(l module)     -- load or reload <module>\n"
                   "(ls)           -- list files in the current directory\n"
                   "(ls dir)       -- list files in directory <dir>\n"
                   "(m)            -- which modules are loaded\n"
                   "(m mod)        -- information about module <mod>\n"
                   "(p expr)       -- print a term\n"
                   "(pp expr)      -- pretty print a term\n"
                   "(pid x y z)    -- convert x, y, z to a pid\n"
                   "(pwd)          -- print working directory\n"
                   "(q)            -- quit - shorthand for init:stop/0\n"
                   "(regs)         -- information about registered processes\n"
                   "\n"
                   "LFE shell built-in forms\n\n"
                   "(reset-environment)             -- reset the environment to its initial state\n"
                   "(run file)                      -- execute all the shell commands in a <file>\n"
                   "(set pattern expr)\n"
                   "(set pattern (when guard) expr) -- evaluate <expr> and match the result with\n"
                   "                                   pattern binding\n"
                   "(slurp file)                    -- slurp in a LFE source <file> and makes\n"
                   "                                   everything available in the shell\n"
                   "(unslurp)                       -- revert back to the state before the last\n"
                   "                                   slurp\n\n"
                   "LFE shell built-in variables\n\n"
                   "+/++/+++      -- the three previous expressions\n"
                   "*/**/***      -- the values of the previous expressions\n"
                   "-             -- the current expression output\n"
                   "$ENV          -- the current LFE environment\n\n"
                 >>).

%% i([Pids]) -> ok.

i() -> c:i().

i(Pids) -> c:i(Pids).

i(X, Y, Z) -> c:i(X, Y, Z).

%% l(Modules) -> ok.
%%  Load the modules.

l(Ms) ->
    foreach(fun (M) -> c:l(M) end, Ms).

%% ls(Dir) -> ok.

ls(Dir) -> apply(c, ls, Dir).

%% clear() -> ok.

clear() -> io:format("\e[H\e[J").

%% m([Modules]) -> ok.
%%  Print module information. Instead of using the c module we do
%%  module info ourselves to get all the data and the right formats.

m() ->
    mformat("Module", "File"),
    lists:foreach(fun ({Mod,File}) ->
                          Mstr = lists:flatten(lfe_io:print1(Mod)),
                          mformat(Mstr, File)
                  end,
                  lists:sort(code:all_loaded())).

mformat(S1, S2) ->
    Fstr = if length(S1) > 20 -> "~s~n                      ~s~n";
              true -> "~-20s  ~s~n"
           end,
    lfe_io:format(Fstr, [S1,S2]).

m(Ms) ->
    foreach(fun (M) -> print_module(M) end, Ms).

print_module(M) ->
    Info = M:module_info(),
    lfe_io:format("Module: ~w~n", [M]),
    print_object_file(M),
    print_md5(Info),
    print_compile_time(Info),
    print_compile_options(Info),
    print_exports(Info),
    print_macros(Info).

print_md5(Info) ->
    case lists:keyfind(md5, 1, Info) of
        {md5,<<MD5:128>>} -> lfe_io:format("MD5: ~.16b~n", [MD5]);
        false -> ok
    end.

print_compile_time(Info) ->
    Cstr = case get_compile_info(Info, time) of
               {Year,Month,Day,Hour,Min,Sec} ->
                   lfe_io:format1("~w-~.2.0w-.2.0~w ~.2.0w:~.2.0w:~.2.0w",
                                  [Year,Month,Day,Hour,Min,Sec]);
               error -> "No compile time info avaliable"
           end,
    lfe_io:format("Compiled: ~s~n", [Cstr]).

print_object_file(M) ->
    case code:is_loaded(M) of
        {file,File} -> lfe_io:format("Object file: ~s~n", [File]);
        _ -> ok
    end.

print_compile_options(Info) ->
    case get_compile_info(Info, options) of     %Export Opts
               Opts when is_list(Opts) -> ok;
               error -> Opts = []
    end,
    lfe_io:format("Compiler options: ~p~n", [Opts]).

print_exports(Info) ->
    lfe_io:format("Exported functions:~n", []),
    Exps = case lists:keyfind(exports, 1, Info) of
               {exports,Es} -> Es;
               false -> []
           end,
    print_names(fun ({N,Ar}) -> lfe_io:format1("~w/~w", [N,Ar]) end, Exps).

print_macros(Info) ->
    lfe_io:format("Exported macros:~n", []),
    Macs = case lists:keyfind(attributes, 1, Info) of
               {attributes,Attrs} ->
                   Fun = fun ({'export-macro',Ms}) -> Ms;
                             (_) -> []
                         end,
                   lists:flatmap(Fun, Attrs);
               false -> []
           end,
    print_names(fun (N) -> lfe_io:print1(N) end, Macs).

print_names(Format, Names) ->
    %% Generate flattened list of strings.
    Strs = lists:map(fun (N) -> lists:flatten(Format(N)) end,
                     lists:sort(Names)),
    %% Split into equal length lists and print out.
    {S1,S2} = lists:split(round(length(Strs)/2), Strs),
    print_name_strings(S1, S2).

print_name_strings([N1|N1s], [N2|N2s]) ->
    lfe_io:format("  ~-30s  ~-30s~n", [N1,N2]),
    print_name_strings(N1s, N2s);
print_name_strings([N1], []) ->
    lfe_io:format("  ~s~n", [N1]);
print_name_strings([], []) -> ok.

get_compile_info(Info, Tag) ->
    case lists:keyfind(compile, 1, Info) of
        {compile,C} ->
            case lists:keyfind(Tag, 1, C) of
                {Tag,Val} -> Val;
                false -> error
            end;
        false -> error
    end.

%% p(Expr [, Depth]) -> ok.
%% pp(Expr [, Depth]) -> ok.
%%  Print/prettyprint a value in LFE format.

p(E) ->
    Cs = lfe_io:print1(E),
    io:put_chars([Cs,$\n]).

p(E, D) ->
    Cs = lfe_io:print1(E, D),
    io:put_chars([Cs,$\n]).

pp(E) ->
    Cs = lfe_io:prettyprint1(E),
    io:put_chars([Cs,$\n]).

pp(E, D) ->
    Cs = lfe_io:prettyprint1(E, D),
    io:put_chars([Cs,$\n]).

%% pid(A, B, C) -> Pid.
%%  Build a pid from its 3 "parts".

pid(A, B, C) -> c:pid(A, B, C).

%% pwd() -> ok.

pwd() -> c:pwd().

%% q() -> ok.

q() -> c:q().

%% flush() -> ok.

flush() -> c:flush().

%% regs() -> ok.

regs() -> c:regs().

%% exit() -> ok.

exit() -> c:q().

%% doc(Mod) -> ok | {error,Error}.
%% doc(Mod, Func) -> ok | {error,Error}.
%% doc(Mod, Func, Arity) -> ok | {error,Error}.
%%  Print out documentation of a module/macro/function. Always try to
%%  find the file and use it as this is the only way to get hold of
%%  the chunks. This may get a later version than is loaded.

%% doc(?Q(What)) -> doc(What);                     %Be kind if they quote it
%% doc(What) ->
%%     [Mod|F] = lfe_lib:split_name(What),

h(Mod) ->
    case lfe_docs:get_module_docs(Mod) of
        {ok,#docs_v1{}=Docs} ->
            Ret = get_module_doc(Mod, Docs),
            format_doc(Ret);
        Error -> Error
    end.

h(Mod, Func) ->
    case lfe_docs:get_module_docs(Mod) of
        {ok,#docs_v1{}=Docs} ->
            Ret = get_macro_doc(Mod, Func, Docs),
            format_doc(Ret);
        Error -> Error
    end.

h(Mod, Func, Arity) ->
    case lfe_docs:get_module_docs(Mod) of
        {ok,#docs_v1{}=Docs} ->
            Ret = get_function_doc(Mod, Func, Arity, Docs),
            format_doc(Ret);
        Error -> Error
    end.

format_doc({error,_}=Error) -> Error;
format_doc(Docs) ->
    {match,Lines} = re:run(Docs, "(.+\n|\n)",
                           [unicode,global,{capture,all_but_first,binary}]),
    Pline = fun (Line) ->
                    io:put_chars(Line),
                    1                           %Output one line
           end,
    paged_output(Pline, Lines),
    ok.


-ifdef(EEP48).

get_module_doc(Mod, #docs_v1{format = ?NATIVE_FORMAT}=Docs) ->
    shell_docs:render(Mod, Docs);
get_module_doc(Mod, #docs_v1{format = ?LFE_FORMAT}=Docs) ->
    lfe_shell_docs:render(Mod, Docs);
get_module_doc(_Mod, #docs_v1{format = Enc}) ->
    {error, {unknown_format, Enc}}.

get_macro_doc(Mod, Name, #docs_v1{format = ?NATIVE_FORMAT}=Docs) ->
    shell_docs:render(Mod, Name, Docs);
get_macro_doc(Mod, Name, #docs_v1{format = ?LFE_FORMAT}=Docs) ->
    lfe_shell_docs:render(Mod, Name, Docs);
get_macro_doc(_Mod, _Name, #docs_v1{format = Enc}) ->
    {error, {unknown_format, Enc}}.

get_function_doc(Mod, Name, Arity, #docs_v1{format = ?NATIVE_FORMAT}=Docs) ->
    shell_docs:render(Mod, Name, Arity, Docs);
get_function_doc(Mod, Name, Arity, #docs_v1{format = ?LFE_FORMAT}=Docs) ->
    lfe_shell_docs:render(Mod, Name, Arity, Docs);
get_function_doc(_Mod, _Name, _Arity, #docs_v1{format = Enc}) ->
    {error, {unknown_format, Enc}}.

-else.

get_module_doc(Mod, #docs_v1{format = ?LFE_FORMAT}=Docs) ->
    lfe_shell_docs:render(Mod, Docs);
get_module_doc(_Mod, #docs_v1{format = Enc}) ->
    {error, {unknown_format, Enc}}.

get_macro_doc(Mod, Name, #docs_v1{format = ?LFE_FORMAT}=Docs) ->
    lfe_shell_docs:render(Mod, Name, Docs);
get_macro_doc(_Mod, _Name, #docs_v1{format = Enc}) ->
    {error, {unknown_format, Enc}}.

get_function_doc(Mod, Name, Arity, #docs_v1{format = ?LFE_FORMAT}=Docs) ->
    lfe_shell_docs:render(Mod, Name, Arity, Docs);
get_function_doc(_Mod, _Name, _Arity, #docs_v1{format = Enc}) ->
    {error, {unknown_format, Enc}}.

-endif.

%% paged_output(PrintItem, Items) -> ok.
%%  Output item lines a page at a time. This can handle an item
%%  returning multiple lines.

paged_output(Pitem, Items) ->
    %% How many rows per "page", just set it to 30 for now.
    Limit = 30,
    paged_output(Pitem, 0, Limit, Items).

paged_output(Pitem, Curr, Limit, Items) when Curr >= Limit ->
    case more() of
        more -> paged_output(Pitem, 0, Limit, Items);
        less -> ok
    end;
paged_output(Pitem, Curr, Limit, [Item|Items]) ->
    Olines = Pitem(Item),
    paged_output(Pitem, Curr + Olines, Limit, Items);
paged_output(_, _, _, []) -> ok.

more() ->
    case io:get_line('More (y/n)? ') of
        "y\n" -> more;
        "c\n" -> more;
        "n\n" -> less;
        "q\n" -> less;
        _ -> more()
    end.
