%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1996-2011. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%
%% Description: Tests supervisor.erl

-module(supervisor_SUITE).

-include_lib("common_test/include/ct.hrl").
-define(TIMEOUT, ?t:minutes(1)).

%% Testserver specific export
-export([all/0, suite/0,groups/0,init_per_suite/1, end_per_suite/1, 
	 init_per_group/2,end_per_group/2, init_per_testcase/2,
	 end_per_testcase/2]).

%% Internal export
-export([init/1, terminate_all_children/1,
         middle9212/0, gen_server9212/0, handle_info/2]).

%% API tests
-export([ sup_start_normal/1, sup_start_ignore_init/1, 
	  sup_start_ignore_child/1, sup_start_ignore_temporary_child/1,
	  sup_start_ignore_temporary_child_start_child/1,
	  sup_start_ignore_temporary_child_start_child_simple/1,
	  sup_start_error_return/1, sup_start_fail/1, sup_stop_infinity/1,
	  sup_stop_timeout/1, sup_stop_brutal_kill/1, child_adm/1,
	  child_adm_simple/1, child_specs/1, extra_return/1]).

%% Tests concept permanent, transient and temporary 
-export([ permanent_normal/1, transient_normal/1,
	  temporary_normal/1,
	  permanent_shutdown/1, transient_shutdown/1,
	  temporary_shutdown/1,
	  permanent_abnormal/1, transient_abnormal/1,
	  temporary_abnormal/1, temporary_bystander/1]).

%% Restart strategy tests 
-export([ one_for_one/1,
	  one_for_one_escalation/1, one_for_all/1,
	  one_for_all_escalation/1,
	  simple_one_for_one/1, simple_one_for_one_escalation/1,
	  rest_for_one/1, rest_for_one_escalation/1,
	  simple_one_for_one_extra/1, simple_one_for_one_shutdown/1]).

%% Misc tests
-export([child_unlink/1, tree/1, count_children_memory/1,
	 do_not_save_start_parameters_for_temporary_children/1,
	 do_not_save_child_specs_for_temporary_children/1,
	 simple_one_for_one_scale_many_temporary_children/1,
         simple_global_supervisor/1, hanging_restart_loop/1,
	 hanging_restart_loop_simple/1]).

%%-------------------------------------------------------------------------

suite() ->
    [{ct_hooks,[ts_install_cth]}].

all() -> 
    [{group, sup_start}, {group, sup_stop}, child_adm,
     child_adm_simple, extra_return, child_specs,
     {group, restart_one_for_one},
     {group, restart_one_for_all},
     {group, restart_simple_one_for_one},
     {group, restart_rest_for_one},
     {group, normal_termination},
     {group, shutdown_termination},
     {group, abnormal_termination}, child_unlink, tree,
     count_children_memory, do_not_save_start_parameters_for_temporary_children,
     do_not_save_child_specs_for_temporary_children,
     simple_one_for_one_scale_many_temporary_children, temporary_bystander,
     simple_global_supervisor, hanging_restart_loop, hanging_restart_loop_simple].

groups() -> 
    [{sup_start, [],
      [sup_start_normal, sup_start_ignore_init,
       sup_start_ignore_child, sup_start_ignore_temporary_child,
       sup_start_ignore_temporary_child_start_child,
       sup_start_ignore_temporary_child_start_child_simple,
       sup_start_error_return, sup_start_fail]},
     {sup_stop, [],
      [sup_stop_infinity, sup_stop_timeout,
       sup_stop_brutal_kill]},
     {normal_termination, [],
      [permanent_normal, transient_normal, temporary_normal]},
     {shutdown_termination, [],
      [permanent_shutdown, transient_shutdown, temporary_shutdown]},
     {abnormal_termination, [],
      [permanent_abnormal, transient_abnormal,
       temporary_abnormal]},
     {restart_one_for_one, [],
      [one_for_one, one_for_one_escalation]},
     {restart_one_for_all, [],
      [one_for_all, one_for_all_escalation]},
     {restart_simple_one_for_one, [],
      [simple_one_for_one, simple_one_for_one_shutdown,
       simple_one_for_one_extra, simple_one_for_one_escalation]},
     {restart_rest_for_one, [],
      [rest_for_one, rest_for_one_escalation]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.

init_per_testcase(count_children_memory, Config) ->
    try erlang:memory() of
	_ ->
	    erts_debug:set_internal_state(available_internal_state, true),
	    Dog = ?t:timetrap(?TIMEOUT),
	    [{watchdog,Dog}|Config]
    catch error:notsup ->
	    {skip, "+Meamin used during test; erlang:memory/1 not available"}
    end;
init_per_testcase(_Case, Config) ->
    Dog = ?t:timetrap(?TIMEOUT),
    [{watchdog,Dog}|Config].

end_per_testcase(count_children_memory, Config) ->
    catch erts_debug:set_internal_state(available_internal_state, false),
    ?t:timetrap_cancel(?config(watchdog,Config)),
    ok;
end_per_testcase(_Case, Config) ->
    ?t:timetrap_cancel(?config(watchdog,Config)),
    ok.

start_link(InitResult) ->
    supervisor:start_link({local, sup_test}, ?MODULE, InitResult).

%% Simulate different supervisors callback.  
init(fail) ->
    erlang:error({badmatch,2});
init(InitResult) ->
    InitResult.

%% Respect proplist return of supervisor:count_children
get_child_counts(Supervisor) ->
    Counts = supervisor:count_children(Supervisor),
    [proplists:get_value(specs, Counts),
     proplists:get_value(active, Counts),
     proplists:get_value(supervisors, Counts),
     proplists:get_value(workers, Counts)].

%%-------------------------------------------------------------------------
%% Test cases starts here.
%% -------------------------------------------------------------------------
%% Tests that the supervisor process starts correctly and that it can
%% be terminated gracefully.
sup_start_normal(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    terminate(Pid, shutdown).

%%-------------------------------------------------------------------------
%% Tests what happens if init-callback returns ignore.
sup_start_ignore_init(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    ignore = start_link(ignore),
    check_exit_reason(normal).

%%-------------------------------------------------------------------------
%% Tests what happens if init-callback returns ignore.
sup_start_ignore_child(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, _Pid}  = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, [ignore]}, 
	      permanent, 1000, worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent,
	      1000, worker, []},

    {ok, undefined} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),

    [{child2, CPid2, worker, []},{child1, undefined, worker, []}]
	= supervisor:which_children(sup_test),
    [2,1,0,2] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% Tests what happens if child's init-callback returns ignore for a
%% temporary child when ChildSpec is returned directly from supervisor
%% init callback.
%% Child spec shall NOT be saved!!!
sup_start_ignore_temporary_child(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child1 = {child1, {supervisor_1, start_child, [ignore]},
	      temporary, 1000, worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, temporary,
	      1000, worker, []},
    {ok, _Pid}  = start_link({ok, {{one_for_one, 2, 3600}, [Child1,Child2]}}),

    [{child2, CPid2, worker, []}] = supervisor:which_children(sup_test),
    true = is_pid(CPid2),
    [1,1,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% Tests what happens if child's init-callback returns ignore for a
%% temporary child when child is started with start_child/2.
%% Child spec shall NOT be saved!!!
sup_start_ignore_temporary_child_start_child(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, _Pid}  = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, [ignore]},
	      temporary, 1000, worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, temporary,
	      1000, worker, []},

    {ok, undefined} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),

    [{child2, CPid2, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% Tests what happens if child's init-callback returns ignore for a
%% temporary child when child is started with start_child/2, and the
%% supervisor is simple_one_for_one.
%% Child spec shall NOT be saved!!!
sup_start_ignore_temporary_child_start_child_simple(Config)
  when is_list(Config) ->
    process_flag(trap_exit, true),
    Child1 = {child1, {supervisor_1, start_child, [ignore]},
	      temporary, 1000, worker, []},
    {ok, _Pid}  = start_link({ok, {{simple_one_for_one, 2, 3600}, [Child1]}}),

    {ok, undefined} = supervisor:start_child(sup_test, []),
    {ok, CPid2} = supervisor:start_child(sup_test, []),

    [{undefined, CPid2, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% Tests what happens if init-callback returns a invalid value.
sup_start_error_return(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {error, Term} = start_link(invalid),
    check_exit_reason(Term).

%%-------------------------------------------------------------------------
%% Tests what happens if init-callback fails.
sup_start_fail(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {error, Term} = start_link(fail),
    check_exit_reason(Term).

%%-------------------------------------------------------------------------
%% See sup_stop/1 when Shutdown = infinity, this walue is allowed for
%% children of type supervisor _AND_ worker.
sup_stop_infinity(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, 
	      permanent, infinity, supervisor, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent,
	      infinity, worker, []},
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    link(CPid1),
    link(CPid2),

    terminate(Pid, shutdown),
    check_exit_reason(CPid1, shutdown),
    check_exit_reason(CPid2, shutdown).

%%-------------------------------------------------------------------------
%% See sup_stop/1 when Shutdown = 1000
sup_stop_timeout(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, 
	      permanent, 1000, worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent,
	      1000, worker, []},
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    link(CPid1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    link(CPid2),

    CPid2 ! {sleep, 200000},

    terminate(Pid, shutdown),

    check_exit_reason(CPid1, shutdown),
    check_exit_reason(CPid2, killed).


%%-------------------------------------------------------------------------
%% See sup_stop/1 when Shutdown = brutal_kill
sup_stop_brutal_kill(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, 
	      permanent, 1000, worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent,
	      brutal_kill, worker, []},
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    link(CPid1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    link(CPid2),

    terminate(Pid, shutdown),

    check_exit_reason(CPid1, shutdown),
    check_exit_reason(CPid2, killed).

%%-------------------------------------------------------------------------
%% The start function provided to start a child may return {ok, Pid}
%% or {ok, Pid, Info}, if it returns the latter check that the
%% supervisor ignores the Info, and includes it unchanged in return
%% from start_child/2 and restart_child/2.
extra_return(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child = {child1, {supervisor_1, start_child, [extra_return]}, 
	     permanent, 1000,
	     worker, []},
    {ok, _Pid} = start_link({ok, {{one_for_one, 2, 3600}, [Child]}}),
    [{child1, CPid, worker, []}] = supervisor:which_children(sup_test),
    link(CPid),
    {error, not_found} = supervisor:terminate_child(sup_test, hej),
    {error, not_found} = supervisor:delete_child(sup_test, hej),
    {error, not_found} = supervisor:restart_child(sup_test, hej),
    {error, running} = supervisor:delete_child(sup_test, child1),
    {error, running} = supervisor:restart_child(sup_test, child1),
    [{child1, CPid, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),

    ok = supervisor:terminate_child(sup_test, child1),
    check_exit_reason(CPid, shutdown),
    [{child1,undefined,worker,[]}] = supervisor:which_children(sup_test),
    [1,0,0,1] = get_child_counts(sup_test),

    {ok, CPid2,extra_return} =
	supervisor:restart_child(sup_test, child1),
    [{child1, CPid2, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),

    ok = supervisor:terminate_child(sup_test, child1),
    ok = supervisor:terminate_child(sup_test, child1),
    ok = supervisor:delete_child(sup_test, child1),
    {error, not_found} = supervisor:restart_child(sup_test, child1),
    [] = supervisor:which_children(sup_test),
    [0,0,0,0] = get_child_counts(sup_test),

    {ok, CPid3, extra_return} = supervisor:start_child(sup_test, Child),
    [{child1, CPid3, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),

    ok.
%%-------------------------------------------------------------------------
%% Test API functions start_child/2, terminate_child/2, delete_child/2
%% restart_child/2, which_children/1, count_children/1. Only correct
%% childspecs are used, handling of incorrect childspecs is tested in
%% child_specs/1.
child_adm(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    {ok, _Pid} = start_link({ok, {{one_for_one, 2, 3600}, [Child]}}),
    [{child1, CPid, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),
    link(CPid),

    %% Start of an already runnig process 
    {error,{already_started, CPid}} =
	supervisor:start_child(sup_test, Child),

    %% Termination
    {error, not_found} = supervisor:terminate_child(sup_test, hej),
    {'EXIT',{noproc,{gen_server,call, _}}} =
	(catch supervisor:terminate_child(foo, child1)),
    ok = supervisor:terminate_child(sup_test, child1),
    check_exit_reason(CPid, shutdown),
    [{child1,undefined,worker,[]}] = supervisor:which_children(sup_test),
    [1,0,0,1] = get_child_counts(sup_test),
    %% Like deleting something that does not exist, it will succeed!
    ok = supervisor:terminate_child(sup_test, child1),

    %% Start of already existing but not running process 
    {error,already_present} = supervisor:start_child(sup_test, Child),

    %% Restart
    {ok, CPid2} = supervisor:restart_child(sup_test, child1),
    [{child1, CPid2, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),
    {error, running} = supervisor:restart_child(sup_test, child1),
    {error, not_found} = supervisor:restart_child(sup_test, child2),

    %% Deletion
    {error, running} = supervisor:delete_child(sup_test, child1),
    {error, not_found} = supervisor:delete_child(sup_test, hej),
    {'EXIT',{noproc,{gen_server,call, _}}} =
	(catch supervisor:delete_child(foo, child1)),
    ok = supervisor:terminate_child(sup_test, child1),
    ok = supervisor:delete_child(sup_test, child1),
    {error, not_found} = supervisor:restart_child(sup_test, child1),
    [] = supervisor:which_children(sup_test),
    [0,0,0,0] = get_child_counts(sup_test),

    %% Start
    {'EXIT',{noproc,{gen_server,call, _}}} =
	(catch supervisor:start_child(foo, Child)),
    {ok, CPid3} = supervisor:start_child(sup_test, Child),
    [{child1, CPid3, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),

    %% Terminate with Pid not allowed when not simple_one_for_one
    {error,not_found} = supervisor:terminate_child(sup_test, CPid3),
    [{child1, CPid3, worker, []}] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),

    {'EXIT',{noproc,{gen_server,call,[foo,which_children,infinity]}}}
	= (catch supervisor:which_children(foo)),
    {'EXIT',{noproc,{gen_server,call,[foo,count_children,infinity]}}}
	= (catch supervisor:count_children(foo)),
    ok.
%%-------------------------------------------------------------------------
%% The API functions terminate_child/2, delete_child/2 restart_child/2
%% are not valid for a simple_one_for_one supervisor check that the
%% correct error message is returned.
child_adm_simple(Config) when is_list(Config) ->
    Child = {child, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    {ok, _Pid} = start_link({ok, {{simple_one_for_one, 2, 3600}, [Child]}}),
    %% In simple_one_for_one all children are added dynamically 
    [] = supervisor:which_children(sup_test),
    [1,0,0,0] = get_child_counts(sup_test),

    %% Start
    {'EXIT',{noproc,{gen_server,call, _}}} =
	(catch supervisor:start_child(foo, [])),
    {ok, CPid1} = supervisor:start_child(sup_test, []),
    [{undefined, CPid1, worker, []}] =
	supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),

    {ok, CPid2} = supervisor:start_child(sup_test, []),
    Children = supervisor:which_children(sup_test),
    2 = length(Children),
    true = lists:member({undefined, CPid2, worker, []}, Children),
    true = lists:member({undefined, CPid1, worker, []}, Children),
    [1,2,0,2] = get_child_counts(sup_test),

    %% Termination
    {error, simple_one_for_one} = supervisor:terminate_child(sup_test, child1),
    [1,2,0,2] = get_child_counts(sup_test),
    ok = supervisor:terminate_child(sup_test,CPid1),
    [_] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),
    false = erlang:is_process_alive(CPid1),
    %% Terminate non-existing proccess is ok
    ok = supervisor:terminate_child(sup_test,CPid1),
    [_] = supervisor:which_children(sup_test),
    [1,1,0,1] = get_child_counts(sup_test),
    %% Terminate pid which is not a child of this supervisor is not ok
    NoChildPid = spawn_link(fun() -> receive after infinity -> ok end end),
    {error, not_found} = supervisor:terminate_child(sup_test, NoChildPid),
    true = erlang:is_process_alive(NoChildPid),

    %% Restart
    {error, simple_one_for_one} = supervisor:restart_child(sup_test, child1),

    %% Deletion
    {error, simple_one_for_one} = supervisor:delete_child(sup_test, child1),
    ok.

%%-------------------------------------------------------------------------
%% Tests child specs, invalid formats should be rejected.
child_specs(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, _Pid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    {error, _} = supervisor:start_child(sup_test, hej),

    %% Bad child specs 
    B1 = {child, mfa, permanent, 1000, worker, []},
    B2 = {child, {m,f,[a]}, prmanent, 1000, worker, []}, 
    B3 = {child, {m,f,[a]}, permanent, -10, worker, []},
    B4 = {child, {m,f,[a]}, permanent, 10, wrker, []},
    B5 = {child, {m,f,[a]}, permanent, 1000, worker, dy},
    B6 = {child, {m,f,[a]}, permanent, 1000, worker, [1,2,3]},

    %% Correct child specs!
    %% <Modules> (last parameter in a child spec) can be [] as we do 
    %% not test code upgrade here.  
    C1 = {child, {m,f,[a]}, permanent, infinity, supervisor, []},
    C2 = {child, {m,f,[a]}, permanent, 1000, supervisor, []},
    C3 = {child, {m,f,[a]}, temporary, 1000, worker, dynamic},
    C4 = {child, {m,f,[a]}, transient, 1000, worker, [m]},
    C5 = {child, {m,f,[a]}, permanent, infinity, worker, [m]},

    {error, {invalid_mfa,mfa}} = supervisor:start_child(sup_test, B1),
    {error, {invalid_restart_type, prmanent}} =
	supervisor:start_child(sup_test, B2),
    {error,  {invalid_shutdown,-10}}
	= supervisor:start_child(sup_test, B3),
    {error, {invalid_child_type,wrker}}
	= supervisor:start_child(sup_test, B4),
    {error, {invalid_modules,dy}}
	= supervisor:start_child(sup_test, B5),

    {error, {invalid_mfa,mfa}} = supervisor:check_childspecs([B1]),
    {error, {invalid_restart_type,prmanent}} =
	supervisor:check_childspecs([B2]),
    {error, {invalid_shutdown,-10}} = supervisor:check_childspecs([B3]),
    {error, {invalid_child_type,wrker}}
	= supervisor:check_childspecs([B4]),
    {error, {invalid_modules,dy}} = supervisor:check_childspecs([B5]),
    {error, {invalid_module, 1}} =
	supervisor:check_childspecs([B6]),

    ok = supervisor:check_childspecs([C1]),
    ok = supervisor:check_childspecs([C2]),
    ok = supervisor:check_childspecs([C3]),
    ok = supervisor:check_childspecs([C4]),
    ok = supervisor:check_childspecs([C5]),
    ok.

%%-------------------------------------------------------------------------
%% A permanent child should always be restarted.
permanent_normal(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),

    terminate(SupPid, CPid1, child1, normal),

    [{child1, Pid ,worker,[]}] = supervisor:which_children(sup_test),
    case is_pid(Pid) of
	true ->
	    ok;
	false ->
	    test_server:fail({permanent_child_not_restarted, Child1})
    end,
    [1,1,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A transient child should not be restarted if it exits with reason
%% normal.
transient_normal(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, transient, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),

    terminate(SupPid, CPid1, child1, normal),

    [{child1,undefined,worker,[]}] = supervisor:which_children(sup_test),
    [1,0,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A temporary process should never be restarted.
temporary_normal(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, temporary, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),

    terminate(SupPid, CPid1, child1, normal),

    [] = supervisor:which_children(sup_test),
    [0,0,0,0] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A permanent child should always be restarted.
permanent_shutdown(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),

    terminate(SupPid, CPid1, child1, shutdown),

    [{child1, CPid2 ,worker,[]}] = supervisor:which_children(sup_test),
    case is_pid(CPid2) of
	true ->
	    ok;
	false ->
	    test_server:fail({permanent_child_not_restarted, Child1})
    end,
    [1,1,0,1] = get_child_counts(sup_test),

    terminate(SupPid, CPid2, child1, {shutdown, some_info}),

    [{child1, CPid3 ,worker,[]}] = supervisor:which_children(sup_test),
    case is_pid(CPid3) of
	true ->
	    ok;
	false ->
	    test_server:fail({permanent_child_not_restarted, Child1})
    end,

    [1,1,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A transient child should not be restarted if it exits with reason
%% shutdown or {shutdown,Term}.
transient_shutdown(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, transient, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),

    terminate(SupPid, CPid1, child1, shutdown),

    [{child1,undefined,worker,[]}] = supervisor:which_children(sup_test),
    [1,0,0,1] = get_child_counts(sup_test),

    {ok, CPid2} = supervisor:restart_child(sup_test, child1),

    terminate(SupPid, CPid2, child1, {shutdown, some_info}),

    [{child1,undefined,worker,[]}] = supervisor:which_children(sup_test),
    [1,0,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A temporary process should never be restarted.
temporary_shutdown(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, temporary, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),

    terminate(SupPid, CPid1, child1, shutdown),

    [] = supervisor:which_children(sup_test),
    [0,0,0,0] = get_child_counts(sup_test),

    {ok, CPid2} = supervisor:start_child(sup_test, Child1),

    terminate(SupPid, CPid2, child1, {shutdown, some_info}),

    [] = supervisor:which_children(sup_test),
    [0,0,0,0] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A permanent child should always be restarted.
permanent_abnormal(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    terminate(SupPid, CPid1, child1, abnormal),

    [{child1, Pid ,worker,[]}] = supervisor:which_children(sup_test),
    case is_pid(Pid) of
	true ->
	    ok;
	false ->
	    test_server:fail({permanent_child_not_restarted, Child1})
    end,
    [1,1,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A transient child should be restarted if it exits with reason abnormal.
transient_abnormal(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, transient, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    terminate(SupPid, CPid1, child1, abnormal),

    [{child1, Pid ,worker,[]}] = supervisor:which_children(sup_test),
    case is_pid(Pid) of
	true ->
	    ok;
	false ->
	    test_server:fail({transient_child_not_restarted, Child1})
    end,
    [1,1,0,1] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A temporary process should never be restarted.
temporary_abnormal(Config) when is_list(Config) ->
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    Child1 = {child1, {supervisor_1, start_child, []}, temporary, 1000,
	      worker, []},

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    terminate(SupPid, CPid1, child1, abnormal),

    [] = supervisor:which_children(sup_test),
    [0,0,0,0] = get_child_counts(sup_test).

%%-------------------------------------------------------------------------
%% A temporary process killed as part of a rest_for_one or one_for_all
%% restart strategy should not be restarted given its args are not
%% saved. Otherwise the supervisor hits its limit and crashes.
temporary_bystander(_Config) ->
    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 100,
	      worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, temporary, 100,
	      worker, []},
    {ok, SupPid1} = supervisor:start_link(?MODULE, {ok, {{one_for_all, 2, 300}, []}}),
    {ok, SupPid2} = supervisor:start_link(?MODULE, {ok, {{rest_for_one, 2, 300}, []}}),
    unlink(SupPid1), % otherwise we crash with it
    unlink(SupPid2), % otherwise we crash with it
    {ok, CPid1} = supervisor:start_child(SupPid1, Child1),
    {ok, _CPid2} = supervisor:start_child(SupPid1, Child2),
    {ok, CPid3} = supervisor:start_child(SupPid2, Child1),
    {ok, _CPid4} = supervisor:start_child(SupPid2, Child2),
    terminate(SupPid1, CPid1, child1, normal),
    terminate(SupPid2, CPid3, child1, normal),
    timer:sleep(350),
    catch link(SupPid1),
    catch link(SupPid2),
    %% The supervisor would die attempting to restart child2
    true = erlang:is_process_alive(SupPid1),
    true = erlang:is_process_alive(SupPid2),
    %% Child2 has not been restarted
    [{child1, _, _, _}] = supervisor:which_children(SupPid1),
    [{child1, _, _, _}] = supervisor:which_children(SupPid2).

%%-------------------------------------------------------------------------
%% Test the one_for_one base case.
one_for_one(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	      worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent, 1000,
	      worker, []},
    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),

    terminate(SupPid, CPid1, child1, abnormal),
    Children = supervisor:which_children(sup_test),
    if length(Children) == 2 ->
	    case lists:keysearch(CPid2, 2, Children) of
		{value, _} -> ok;
		_ ->  test_server:fail(bad_child)
	    end;
       true ->  test_server:fail({bad_child_list, Children})
    end,
    [2,2,0,2] = get_child_counts(sup_test),

    %% Test restart frequency property
    terminate(SupPid, CPid2, child2, abnormal),

    [{Id4, Pid4, _, _}|_] = supervisor:which_children(sup_test),
    terminate(SupPid, Pid4, Id4, abnormal),
    check_exit([SupPid]).

%%-------------------------------------------------------------------------
%% Test restart escalation on a one_for_one supervisor.
one_for_one_escalation(Config) when is_list(Config) ->
    process_flag(trap_exit, true),

    Child1 = {child1, {supervisor_1, start_child, [error]},
	      permanent, 1000,
	      worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent, 1000,
	      worker, []},

    {ok, SupPid} = start_link({ok, {{one_for_one, 4, 3600}, []}}),
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    link(CPid2),

    terminate(SupPid, CPid1, child1, abnormal),
    check_exit([SupPid, CPid2]).


%%-------------------------------------------------------------------------
%% Test the one_for_all base case.
one_for_all(Config) when is_list(Config) ->
    process_flag(trap_exit, true),

    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    {ok, SupPid} = start_link({ok, {{one_for_all, 2, 3600}, []}}),
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    link(CPid2),

    terminate(SupPid, CPid1, child1, abnormal),
    check_exit([CPid2]),

    Children = supervisor:which_children(sup_test),
    if length(Children) == 2 -> ok;
       true ->
	    test_server:fail({bad_child_list, Children})
    end,

    %% Test that no old children is still alive
    not_in_child_list([CPid1, CPid2], lists:map(fun({_,P,_,_}) -> P end, Children)),

    [2,2,0,2] = get_child_counts(sup_test),

    %%% Test restart frequency property
    [{Id3, Pid3, _, _}|_] = supervisor:which_children(sup_test),
    terminate(SupPid, Pid3, Id3, abnormal),
    [{Id4, Pid4, _, _}|_] = supervisor:which_children(sup_test),
    terminate(SupPid, Pid4, Id4, abnormal),
    check_exit([SupPid]).


%%-------------------------------------------------------------------------
%% Test restart escalation on a one_for_all supervisor.
one_for_all_escalation(Config) when is_list(Config) ->
    process_flag(trap_exit, true),

    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    Child2 = {child2, {supervisor_1, start_child, [error]},
	      permanent, 1000,
	     worker, []},
    {ok, SupPid} = start_link({ok, {{one_for_all, 4, 3600}, []}}),
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    link(CPid2),

    terminate(SupPid, CPid1, child1, abnormal),
    check_exit([CPid2, SupPid]).


%%-------------------------------------------------------------------------
%% Test the simple_one_for_one base case.
simple_one_for_one(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child = {child, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    {ok, SupPid} = start_link({ok, {{simple_one_for_one, 2, 3600}, [Child]}}),
    {ok, CPid1} = supervisor:start_child(sup_test, []),
    {ok, CPid2} = supervisor:start_child(sup_test, []),

    terminate(SupPid, CPid1, child1, abnormal),

    Children = supervisor:which_children(sup_test),
    if length(Children) == 2 ->
	    case lists:keysearch(CPid2, 2, Children) of
		{value, _} -> ok;
		_ ->  test_server:fail(bad_child)
	    end;
       true ->  test_server:fail({bad_child_list, Children})
    end,
    [1,2,0,2] = get_child_counts(sup_test),

    %% Test restart frequency property
    terminate(SupPid, CPid2, child2, abnormal),

    [{Id4, Pid4, _, _}|_] = supervisor:which_children(sup_test),

    terminate(SupPid, Pid4, Id4, abnormal),
    check_exit([SupPid]).


%%-------------------------------------------------------------------------
%% Test simple_one_for_one children shutdown accordingly to the
%% supervisor's shutdown strategy.
simple_one_for_one_shutdown(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    ShutdownTime = 1000,
    Child = {child, {supervisor_2, start_child, []},
             permanent, 2*ShutdownTime, worker, []},
    {ok, SupPid} = start_link({ok, {{simple_one_for_one, 2, 3600}, [Child]}}),

    %% Will be gracefully shutdown
    {ok, _CPid1} = supervisor:start_child(sup_test, [ShutdownTime]),
    {ok, _CPid2} = supervisor:start_child(sup_test, [ShutdownTime]),

    %% Will be killed after 2*ShutdownTime milliseconds
    {ok, _CPid3} = supervisor:start_child(sup_test, [5*ShutdownTime]),

    {T, ok} = timer:tc(fun terminate/2, [SupPid, shutdown]),
    if T < 1000*ShutdownTime ->
            %% Because supervisor's children wait before exiting, it can't
            %% terminate quickly
            test_server:fail({shutdown_too_short, T});
       T >= 1000*5*ShutdownTime ->
            test_server:fail({shutdown_too_long, T});
       true ->
            check_exit([SupPid])
    end.


%%-------------------------------------------------------------------------
%% Tests automatic restart of children who's start function return
%% extra info.
simple_one_for_one_extra(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child = {child, {supervisor_1, start_child, [extra_info]}, 
	     permanent, 1000, worker, []},
    {ok, SupPid} = start_link({ok, {{simple_one_for_one, 2, 3600}, [Child]}}),
    {ok, CPid1, extra_info} = supervisor:start_child(sup_test, []),
    {ok, CPid2, extra_info} = supervisor:start_child(sup_test, []),
    link(CPid2),
    terminate(SupPid, CPid1, child1, abnormal),
    Children = supervisor:which_children(sup_test),
    if length(Children) == 2 ->
	    case lists:keysearch(CPid2, 2, Children) of
		{value, _} -> ok;
		_ ->  test_server:fail(bad_child)
	    end;
       true ->  test_server:fail({bad_child_list, Children})
    end,
    [1,2,0,2] = get_child_counts(sup_test),
    terminate(SupPid, CPid2, child2, abnormal),
    [{Id4, Pid4, _, _}|_] = supervisor:which_children(sup_test),
    terminate(SupPid, Pid4, Id4, abnormal),
    check_exit([SupPid]).

%%-------------------------------------------------------------------------
%% Test restart escalation on a simple_one_for_one supervisor.
simple_one_for_one_escalation(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child = {child, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    {ok, SupPid} = start_link({ok, {{simple_one_for_one, 4, 3600}, [Child]}}),
    {ok, CPid1} = supervisor:start_child(sup_test, [error]),
    link(CPid1),
    {ok, CPid2} = supervisor:start_child(sup_test, []),
    link(CPid2),

    terminate(SupPid, CPid1, child, abnormal),
    check_exit([SupPid, CPid2]).

%%-------------------------------------------------------------------------
%% Test the rest_for_one base case.
rest_for_one(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    Child2 = {child2, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    Child3 = {child3, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    {ok, SupPid} = start_link({ok, {{rest_for_one, 2, 3600}, []}}),
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    link(CPid1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    {ok, CPid3} = supervisor:start_child(sup_test, Child3),
    link(CPid3),
    [3,3,0,3] = get_child_counts(sup_test),

    terminate(SupPid, CPid2, child2, abnormal),

    %% Check that Cpid3 did die
    check_exit([CPid3]),

    Children = supervisor:which_children(sup_test),
    is_in_child_list([CPid1], Children),

    if length(Children) == 3 ->
	    ok;
       true ->
	    test_server:fail({bad_child_list, Children})
    end,
    [3,3,0,3] = get_child_counts(sup_test),

    %% Test that no old children is still alive
    Pids = lists:map(fun({_,P,_,_}) -> P end, Children),
    not_in_child_list([CPid2, CPid3], Pids),
    in_child_list([CPid1], Pids),

    %% Test restart frequency property
    [{child3, Pid3, _, _}|_] = supervisor:which_children(sup_test),

    terminate(SupPid, Pid3, child3, abnormal),

    [_,{child2, Pid4, _, _}|_] = supervisor:which_children(sup_test),

    terminate(SupPid, Pid4, child2, abnormal),
    check_exit([SupPid]).

%%-------------------------------------------------------------------------
%% Test restart escalation on a rest_for_one supervisor.
rest_for_one_escalation(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child1 = {child1, {supervisor_1, start_child, []}, permanent, 1000,
	     worker, []},
    Child2 = {child2, {supervisor_1, start_child, [error]},
	      permanent, 1000,
	     worker, []},
    {ok, SupPid} = start_link({ok, {{rest_for_one, 4, 3600}, []}}),
    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    {ok, CPid2} = supervisor:start_child(sup_test, Child2),
    link(CPid2),

    terminate(SupPid, CPid1, child1, abnormal),
    check_exit([CPid2, SupPid]).

%%-------------------------------------------------------------------------
%% Test that the supervisor does not hang forever if the child unliks
%% and then is terminated by the supervisor.
child_unlink(Config) when is_list(Config) ->

    {ok, SupPid} = start_link({ok, {{one_for_one, 2, 3600}, []}}),

    Child = {naughty_child, {naughty_child, 
			     start_link, [SupPid]}, permanent, 
	     1000, worker, [supervisor_SUITE]},

    {ok, _ChildPid} = supervisor:start_child(sup_test, Child),

    Pid = spawn(supervisor, terminate_child, [SupPid, naughty_child]),

    SupPid ! foo,
    timer:sleep(5000),
    %% If the supervisor did not hang it will have got rid of the 
    %% foo message that we sent.
    case erlang:process_info(SupPid, message_queue_len) of
	{message_queue_len, 0}->
	    ok;
	_ ->
	    exit(Pid, kill),
	    test_server:fail(supervisor_hangs)
    end.
%%-------------------------------------------------------------------------
%% Test a basic supervison tree.
tree(Config) when is_list(Config) ->
    process_flag(trap_exit, true),

    Child1 = {child1, {supervisor_1, start_child, []},
	      permanent, 1000,
	      worker, []},
    Child2 = {child2, {supervisor_1, start_child, []},
	      permanent, 1000,
	      worker, []},
    Child3 = {child3, {supervisor_1, start_child, [error]},
	      permanent, 1000,
	      worker, []},
    Child4 = {child4, {supervisor_1, start_child, []},
	      permanent, 1000,
	      worker, []},

    ChildSup1 = {supchild1, 
		 {supervisor, start_link,
		  [?MODULE, {ok, {{one_for_one, 4, 3600}, [Child1, Child2]}}]},
		 permanent, infinity,
		 supervisor, []},
    ChildSup2 = {supchild2, 
		 {supervisor, start_link, 
		  [?MODULE, {ok, {{one_for_one, 4, 3600}, []}}]},
		 permanent, infinity,
		 supervisor, []},

    %% Top supervisor
    {ok, SupPid} = start_link({ok, {{one_for_all, 4, 3600}, []}}),

    %% Child supervisors  
    {ok, Sup1} = supervisor:start_child(SupPid, ChildSup1),
    {ok, Sup2} = supervisor:start_child(SupPid, ChildSup2),
    [2,2,2,0] = get_child_counts(SupPid),

    %% Workers
    [{_, CPid2, _, _},{_, CPid1, _, _}] =
	supervisor:which_children(Sup1),
    [2,2,0,2] = get_child_counts(Sup1),
    [0,0,0,0] = get_child_counts(Sup2),

    %% Dynamic children
    {ok, CPid3} = supervisor:start_child(Sup2, Child3),
    {ok, CPid4} = supervisor:start_child(Sup2, Child4),
    [2,2,0,2] = get_child_counts(Sup1),
    [2,2,0,2] = get_child_counts(Sup2),

    %% Test that the only the process that dies is restarted
    terminate(Sup2, CPid4, child4, abnormal),

    [{_, CPid2, _, _},{_, CPid1, _, _}] =
	supervisor:which_children(Sup1),
    [2,2,0,2] = get_child_counts(Sup1),

    [{_, NewCPid4, _, _},{_, CPid3, _, _}] =
	supervisor:which_children(Sup2),
    [2,2,0,2] = get_child_counts(Sup2),

    false = NewCPid4 == CPid4,

    %% Test that supervisor tree is restarted, but not dynamic children.
    terminate(Sup2, CPid3, child3, abnormal),

    timer:sleep(1000),

    [{supchild2, NewSup2, _, _},{supchild1, NewSup1, _, _}] =
	supervisor:which_children(SupPid),
    [2,2,2,0] = get_child_counts(SupPid),

    [{child2, _, _, _},{child1, _, _, _}]  =
	supervisor:which_children(NewSup1),
    [2,2,0,2] = get_child_counts(NewSup1),

    [] = supervisor:which_children(NewSup2),
    [0,0,0,0] = get_child_counts(NewSup2).

%%-------------------------------------------------------------------------
%% Test that count_children does not eat memory.
count_children_memory(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child = {child, {supervisor_1, start_child, []}, temporary, 1000,
	     worker, []},
    {ok, SupPid} = start_link({ok, {{simple_one_for_one, 2, 3600}, [Child]}}),
    [supervisor:start_child(sup_test, []) || _Ignore <- lists:seq(1,1000)],

    garbage_collect(),
    _Size1 = proc_memory(),
    Children = supervisor:which_children(sup_test),
    _Size2 = proc_memory(),
    ChildCount = get_child_counts(sup_test),
    _Size3 = proc_memory(),

    [supervisor:start_child(sup_test, []) || _Ignore2 <- lists:seq(1,1000)],

    garbage_collect(),
    Children2 = supervisor:which_children(sup_test),
    Size4 = proc_memory(),
    ChildCount2 = get_child_counts(sup_test),
    Size5 = proc_memory(),

    garbage_collect(),
    Children3 = supervisor:which_children(sup_test),
    Size6 = proc_memory(),
    ChildCount3 = get_child_counts(sup_test),
    Size7 = proc_memory(),

    1000 = length(Children),
    [1,1000,0,1000] = ChildCount,
    2000 = length(Children2),
    [1,2000,0,2000] = ChildCount2,
    Children3 = Children2,
    ChildCount3 = ChildCount2,

    %% count_children consumes memory using an accumulator function,
    %% but the space can be reclaimed incrementally,
    %% which_children may generate garbage that will be reclaimed later.
    case (Size5 =< Size4) of
	true -> ok;
	false ->
	    test_server:fail({count_children, used_more_memory,Size4,Size5})
    end,
    case Size7 =< Size6 of
	true -> ok;
	false ->
	    test_server:fail({count_children, used_more_memory,Size6,Size7})
    end,

    [terminate(SupPid, Pid, child, kill) || {undefined, Pid, worker, _Modules} <- Children3],
    [1,0,0,0] = get_child_counts(sup_test).

proc_memory() ->
    erts_debug:set_internal_state(wait, deallocations),
    erlang:memory(processes_used).

%%-------------------------------------------------------------------------
%% Temporary children shall not be restarted so they should not save
%% start parameters, as it potentially can take up a huge amount of
%% memory for no purpose.
do_not_save_start_parameters_for_temporary_children(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    dont_save_start_parameters_for_temporary_children(one_for_all),
    dont_save_start_parameters_for_temporary_children(one_for_one),
    dont_save_start_parameters_for_temporary_children(rest_for_one),
    dont_save_start_parameters_for_temporary_children(simple_one_for_one).

start_children(_,_, 0) ->
    ok;
start_children(Sup, Args, N) ->
    Spec = child_spec(Args, N),
    {ok, _, _} = supervisor:start_child(Sup, Spec),
    start_children(Sup, Args, N-1).

child_spec([_|_] = SimpleOneForOneArgs, _) ->
    SimpleOneForOneArgs;
child_spec({Name, MFA, RestartType, Shutdown, Type, Modules}, N) ->
    NewName = list_to_atom((atom_to_list(Name) ++ integer_to_list(N))),
    {NewName, MFA, RestartType, Shutdown, Type, Modules}.

%%-------------------------------------------------------------------------
%% Temporary children shall not be restarted so supervisors should not
%% save their spec when they terminate.
do_not_save_child_specs_for_temporary_children(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    dont_save_child_specs_for_temporary_children(one_for_all, kill),
    dont_save_child_specs_for_temporary_children(one_for_one, kill),
    dont_save_child_specs_for_temporary_children(rest_for_one, kill),

    dont_save_child_specs_for_temporary_children(one_for_all, normal),
    dont_save_child_specs_for_temporary_children(one_for_one, normal),
    dont_save_child_specs_for_temporary_children(rest_for_one, normal),

    dont_save_child_specs_for_temporary_children(one_for_all, abnormal),
    dont_save_child_specs_for_temporary_children(one_for_one, abnormal),
    dont_save_child_specs_for_temporary_children(rest_for_one, abnormal),

    dont_save_child_specs_for_temporary_children(one_for_all, supervisor),
    dont_save_child_specs_for_temporary_children(one_for_one, supervisor),
    dont_save_child_specs_for_temporary_children(rest_for_one, supervisor).

%%-------------------------------------------------------------------------
dont_save_start_parameters_for_temporary_children(simple_one_for_one = Type) ->
    Permanent = {child, {supervisor_1, start_child, []},
		 permanent, 1000, worker, []},
    Transient = {child, {supervisor_1, start_child, []},
		 transient, 1000, worker, []},
    Temporary = {child, {supervisor_1, start_child, []},
		 temporary, 1000, worker, []},
    {ok, Sup1} = supervisor:start_link(?MODULE, {ok, {{Type, 2, 3600}, [Permanent]}}),
    {ok, Sup2} = supervisor:start_link(?MODULE, {ok, {{Type, 2, 3600}, [Transient]}}),
    {ok, Sup3} = supervisor:start_link(?MODULE, {ok, {{Type, 2, 3600}, [Temporary]}}),

    LargeList = lists:duplicate(10, "Potentially large"),

    start_children(Sup1, [LargeList], 100),
    start_children(Sup2, [LargeList], 100),
    start_children(Sup3, [LargeList], 100),

    [{memory,Mem1}] = process_info(Sup1, [memory]),
    [{memory,Mem2}] = process_info(Sup2, [memory]),
    [{memory,Mem3}] = process_info(Sup3, [memory]),

    true = (Mem3 < Mem1)  and  (Mem3 < Mem2),

    terminate(Sup1, shutdown),
    terminate(Sup2, shutdown),
    terminate(Sup3, shutdown);

dont_save_start_parameters_for_temporary_children(Type) ->
    {ok, Sup1} = supervisor:start_link(?MODULE, {ok, {{Type, 2, 3600}, []}}),
    {ok, Sup2} = supervisor:start_link(?MODULE, {ok, {{Type, 2, 3600}, []}}),
    {ok, Sup3} = supervisor:start_link(?MODULE, {ok, {{Type, 2, 3600}, []}}),

    LargeList = lists:duplicate(10, "Potentially large"),

    Permanent = {child1, {supervisor_1, start_child, [LargeList]},
		 permanent, 1000, worker, []},
    Transient = {child2, {supervisor_1, start_child, [LargeList]},
		 transient, 1000, worker, []},
    Temporary = {child3, {supervisor_1, start_child, [LargeList]},
		 temporary, 1000, worker, []},

    start_children(Sup1, Permanent, 100),
    start_children(Sup2, Transient, 100),
    start_children(Sup3, Temporary, 100),

    [{memory,Mem1}] = process_info(Sup1, [memory]),
    [{memory,Mem2}] = process_info(Sup2, [memory]),
    [{memory,Mem3}] = process_info(Sup3, [memory]),

    true = (Mem3 < Mem1)  and  (Mem3 < Mem2),

    terminate(Sup1, shutdown),
    terminate(Sup2, shutdown),
    terminate(Sup3, shutdown).

dont_save_child_specs_for_temporary_children(Type, TerminateHow)->
    {ok, Sup} =
	supervisor:start_link(?MODULE, {ok, {{Type, 2, 3600}, []}}),

    Permanent = {child1, {supervisor_1, start_child, []},
		 permanent, 1000, worker, []},
    Transient = {child2, {supervisor_1, start_child, []},
		 transient, 1000, worker, []},
    Temporary = {child3, {supervisor_1, start_child, []},
		 temporary, 1000, worker, []},

    permanent_child_spec_saved(Permanent, Sup, TerminateHow),

    transient_child_spec_saved(Transient, Sup, TerminateHow),

    temporary_child_spec_not_saved(Temporary, Sup, TerminateHow),

    terminate(Sup, shutdown).

permanent_child_spec_saved(ChildSpec, Sup, supervisor = TerminateHow) ->
    already_present(Sup, ChildSpec, TerminateHow);

permanent_child_spec_saved(ChildSpec, Sup, TerminateHow) ->
    restarted(Sup, ChildSpec, TerminateHow).

transient_child_spec_saved(ChildSpec, Sup, supervisor = TerminateHow) ->
    already_present(Sup, ChildSpec, TerminateHow);

transient_child_spec_saved(ChildSpec, Sup, normal = TerminateHow) ->
    already_present(Sup, ChildSpec, TerminateHow);

transient_child_spec_saved(ChildSpec, Sup, TerminateHow) ->
    restarted(Sup, ChildSpec, TerminateHow).

temporary_child_spec_not_saved({Id, _,_,_,_,_} = ChildSpec, Sup, TerminateHow) ->
    {ok, Pid} = supervisor:start_child(Sup, ChildSpec),
    terminate(Sup, Pid, Id, TerminateHow),
    {ok, _} = supervisor:start_child(Sup, ChildSpec).

already_present(Sup, {Id,_,_,_,_,_} = ChildSpec, TerminateHow) ->
    {ok, Pid} = supervisor:start_child(Sup, ChildSpec),
    terminate(Sup, Pid, Id, TerminateHow),
    {error, already_present} = supervisor:start_child(Sup, ChildSpec),
    {ok, _} = supervisor:restart_child(Sup, Id).

restarted(Sup, {Id,_,_,_,_,_} = ChildSpec, TerminateHow) ->
    {ok, Pid} = supervisor:start_child(Sup, ChildSpec),
    terminate(Sup, Pid, Id, TerminateHow),
    %% Permanent processes will be restarted by the supervisor
    %% when not terminated by api
    {error, {already_started, _}} = supervisor:start_child(Sup, ChildSpec).


%%-------------------------------------------------------------------------
%% OTP-9242: Pids for dynamic temporary children were saved as a list,
%% which caused bad scaling when adding/deleting many processes.
simple_one_for_one_scale_many_temporary_children(_Config) ->
    process_flag(trap_exit, true),
    Child = {child, {supervisor_1, start_child, []}, temporary, 1000,
	     worker, []},
    {ok, _SupPid} = start_link({ok, {{simple_one_for_one, 2, 3600}, [Child]}}),

    C1 = [begin 
		 {ok,P} = supervisor:start_child(sup_test,[]), 
		 P
	     end || _<- lists:seq(1,1000)],
    {T1,done} = timer:tc(?MODULE,terminate_all_children,[C1]),
    
    C2 = [begin 
		 {ok,P} = supervisor:start_child(sup_test,[]), 
		 P
	     end || _<- lists:seq(1,10000)],
    {T2,done} = timer:tc(?MODULE,terminate_all_children,[C2]),
    
    if T1 > 0 ->
	    Scaling = T2 div T1,
	    if Scaling > 20 ->
		    %% The scaling shoul be linear (i.e.10, really), but we
		    %% give some extra here to avoid failing the test
		    %% unecessarily.
		    ?t:fail({bad_scaling,Scaling});
	       true ->
		    ok
	    end;
       true ->
	    %% Means T2 div T1 -> infinity
	    ok
    end.
    

terminate_all_children([C|Cs]) ->
    ok = supervisor:terminate_child(sup_test,C),
    terminate_all_children(Cs);
terminate_all_children([]) ->
    done.


%%-------------------------------------------------------------------------
%% OTP-9212. Restart of global supervisor.
simple_global_supervisor(_Config) ->
    kill_supervisor(),
    kill_worker(),
    exit_worker(),
    restart_worker(),
    ok.

kill_supervisor() ->
    {Top, Sup2_1, Server_1} = start9212(),

    %% Killing a supervisor isn't really supported, but try it anyway...
    exit(Sup2_1, kill),
    timer:sleep(200),
    Sup2_2 = global:whereis_name(sup2),
    Server_2 = global:whereis_name(server),
    true = is_pid(Sup2_2),
    true = is_pid(Server_2),
    true = Sup2_1 =/= Sup2_2,
    true = Server_1 =/= Server_2,

    stop9212(Top).

handle_info({fail, With, After}, _State) ->
    timer:sleep(After),
    erlang:error(With).

kill_worker() ->
    {Top, _Sup2, Server_1} = start9212(),
    exit(Server_1, kill),
    timer:sleep(200),
    Server_2 = global:whereis_name(server),
    true = is_pid(Server_2),
    true = Server_1 =/= Server_2,
    stop9212(Top).

exit_worker() ->
    %% Very much the same as kill_worker().
    {Top, _Sup2, Server_1} = start9212(),
    Server_1 ! {fail, normal, 0},
    timer:sleep(200),
    Server_2 = global:whereis_name(server),
    true = is_pid(Server_2),
    true = Server_1 =/= Server_2,
    stop9212(Top).

restart_worker() ->
    {Top, _Sup2, Server_1} = start9212(),
    ok = supervisor:terminate_child({global, sup2}, child),
    {ok, _Child} = supervisor:restart_child({global, sup2}, child),
    Server_2 = global:whereis_name(server),
    true = is_pid(Server_2),
    true = Server_1 =/= Server_2,
    stop9212(Top).

start9212() ->
    Middle = {middle,{?MODULE,middle9212,[]}, permanent,2000,supervisor,[]},
    InitResult = {ok, {{one_for_all,3,60}, [Middle]}},
    {ok, TopPid} = start_link(InitResult),

    Sup2 = global:whereis_name(sup2),
    Server = global:whereis_name(server),
    true = is_pid(Sup2),
    true = is_pid(Server),
    {TopPid, Sup2, Server}.

stop9212(Top) ->
    Old = process_flag(trap_exit, true),
    exit(Top, kill),
    timer:sleep(200),
    undefined = global:whereis_name(sup2),
    undefined = global:whereis_name(server),
    check_exit([Top]),
    _ = process_flag(trap_exit, Old),
    ok.

middle9212() ->
    Child = {child, {?MODULE,gen_server9212,[]},permanent, 2000, worker, []},
    InitResult = {ok, {{one_for_all,3,60}, [Child]}},
    supervisor:start_link({global,sup2}, ?MODULE, InitResult).

gen_server9212() ->
    InitResult = {ok, []},
    gen_server:start_link({global,server}, ?MODULE, InitResult, []).


%%-------------------------------------------------------------------------
%% Test that child and supervisor can be shutdown while hanging in restart loop.
%% See OTP-9549.
hanging_restart_loop(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = start_link({ok, {{one_for_one, 8, 10}, []}}),
    Child1 = {child1, {supervisor_deadlock, start_child, []},
	      permanent, brutal_kill, worker, []},

    %% Ets table with state read by supervisor_deadlock.erl
    ets:new(supervisor_deadlock,[set,named_table,public]),
    ets:insert(supervisor_deadlock,{fail_start,false}),

    {ok, CPid1} = supervisor:start_child(sup_test, Child1),
    link(CPid1),

    ets:insert(supervisor_deadlock,{fail_start,true}),
    supervisor_deadlock:restart_child(),
    timer:sleep(2000), % allow restart to happen before proceeding

    {error, already_present} = supervisor:start_child(sup_test, Child1),
    {error, restarting} = supervisor:restart_child(sup_test, child1),
    {error, restarting} = supervisor:delete_child(sup_test, child1),
    [{child1,restarting,worker,[]}] = supervisor:which_children(sup_test),
    [1,0,0,1] = get_child_counts(sup_test),

    ok = supervisor:terminate_child(sup_test, child1),
    check_exit_reason(CPid1, error),
    [{child1,undefined,worker,[]}] = supervisor:which_children(sup_test),

    ets:insert(supervisor_deadlock,{fail_start,false}),
    {ok, CPid2} = supervisor:restart_child(sup_test, child1),
    link(CPid2),

    ets:insert(supervisor_deadlock,{fail_start,true}),
    supervisor_deadlock:restart_child(),
    timer:sleep(2000), % allow restart to happen before proceeding

    %% Terminating supervisor.
    %% OTP-9549 fixes so this does not give a timetrap timeout -
    %% i.e. that supervisor does not hang in restart loop.
    terminate(Pid,shutdown),

    %% Check that child died with reason from 'restart' request above
    check_exit_reason(CPid2, error),
    undefined = whereis(sup_test),
    ok.

%%-------------------------------------------------------------------------
%% Test that child and supervisor can be shutdown while hanging in
%% restart loop, simple_one_for_one.
%% See OTP-9549.
hanging_restart_loop_simple(Config) when is_list(Config) ->
    process_flag(trap_exit, true),
    Child1 = {child1, {supervisor_deadlock, start_child, []},
	      permanent, brutal_kill, worker, []},
    {ok, Pid} = start_link({ok, {{simple_one_for_one, 8, 10}, [Child1]}}),

    %% Ets table with state read by supervisor_deadlock.erl
    ets:new(supervisor_deadlock,[set,named_table,public]),
    ets:insert(supervisor_deadlock,{fail_start,false}),

    {ok, CPid1} = supervisor:start_child(sup_test, []),
    link(CPid1),

    ets:insert(supervisor_deadlock,{fail_start,true}),
    supervisor_deadlock:restart_child(),
    timer:sleep(2000), % allow restart to happen before proceeding

    {error, simple_one_for_one} = supervisor:restart_child(sup_test, child1),
    {error, simple_one_for_one} = supervisor:delete_child(sup_test, child1),
    [{undefined,restarting,worker,[]}] = supervisor:which_children(sup_test),
    [1,0,0,1] = get_child_counts(sup_test),

    ok = supervisor:terminate_child(sup_test, CPid1),
    check_exit_reason(CPid1, error),
    [] = supervisor:which_children(sup_test),

    ets:insert(supervisor_deadlock,{fail_start,false}),
    {ok, CPid2} = supervisor:start_child(sup_test, []),
    link(CPid2),

    ets:insert(supervisor_deadlock,{fail_start,true}),
    supervisor_deadlock:restart_child(),
    timer:sleep(2000), % allow restart to happen before proceeding

    %% Terminating supervisor.
    %% OTP-9549 fixes so this does not give a timetrap timeout -
    %% i.e. that supervisor does not hang in restart loop.
    terminate(Pid,shutdown),

    %% Check that child died with reason from 'restart' request above
    check_exit_reason(CPid2, error),
    undefined = whereis(sup_test),
    ok.

%%-------------------------------------------------------------------------
terminate(Pid, Reason) when Reason =/= supervisor ->
    terminate(dummy, Pid, dummy, Reason).

terminate(Sup, _, ChildId, supervisor) ->
    ok = supervisor:terminate_child(Sup, ChildId);
terminate(_, ChildPid, _, kill) ->
    Ref = erlang:monitor(process, ChildPid),
    exit(ChildPid, kill),
    receive
	{'DOWN', Ref, process, ChildPid, killed} ->
	    ok
    end;
terminate(_, ChildPid, _, shutdown) ->
    Ref = erlang:monitor(process, ChildPid),
    exit(ChildPid, shutdown),
    receive
	{'DOWN', Ref, process, ChildPid, shutdown} ->
	    ok
    end;
terminate(_, ChildPid, _, {shutdown, Term}) ->
    Ref = erlang:monitor(process, ChildPid),
    exit(ChildPid, {shutdown, Term}),
    receive
	{'DOWN', Ref, process, ChildPid, {shutdown, Term}} ->
	    ok
    end;
terminate(_, ChildPid, _, normal) ->
    Ref = erlang:monitor(process, ChildPid),
    ChildPid ! stop,
    receive
	{'DOWN', Ref, process, ChildPid, normal} ->
	    ok
    end;
terminate(_, ChildPid, _,abnormal) ->
    Ref = erlang:monitor(process, ChildPid),
    ChildPid ! die,
    receive
	{'DOWN', Ref, process, ChildPid, died} ->
	    ok
    end.

in_child_list([], _) ->
    true;
in_child_list([Pid | Rest], Pids) ->
    case is_in_child_list(Pid, Pids) of
	true ->
	    in_child_list(Rest, Pids);
	false ->
	    test_server:fail(child_should_be_alive)
    end.
not_in_child_list([], _) ->
    true;
not_in_child_list([Pid | Rest], Pids) ->
    case is_in_child_list(Pid, Pids) of
	true ->
	    test_server:fail(child_should_not_be_alive);
	false ->
	    not_in_child_list(Rest, Pids)
    end.

is_in_child_list(Pid, ChildPids) ->
    lists:member(Pid, ChildPids).

check_exit([]) ->
    ok;
check_exit([Pid | Pids]) ->
    receive
	{'EXIT', Pid, _} ->
	    check_exit(Pids)
    end.

check_exit_reason(Reason) ->
    receive
	{'EXIT', _, Reason} ->
	    ok;
	{'EXIT', _, Else} ->
	    test_server:fail({bad_exit_reason, Else})
    end.

check_exit_reason(Pid, Reason) ->
    receive
	{'EXIT', Pid, Reason} ->
	    ok;
	{'EXIT', Pid, Else} ->
	    test_server:fail({bad_exit_reason, Else})
    end.
