%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Service API Batch==
%%% A service that provides batch execution of CloudI services.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2019-2023 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2019-2023 Michael Truog
%%% @version 2.0.8 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_api_batch).
-author('mjtruog at protonmail dot com').

-behaviour(cloudi_service).

%% external interface
-export([queue/3,
         queue/4,
         queue_clear/3,
         queue_clear/4,
         queue_suspend/3,
         queue_suspend/4,
         queue_resume/3,
         queue_resume/4,
         services_add/4,
         services_add/5,
         services_remove/3,
         services_remove/4,
         services_restart/3,
         services_restart/4]).

%% cloudi_service callbacks
-export([cloudi_service_init/4,
         cloudi_service_handle_request/11,
         cloudi_service_handle_info/3,
         cloudi_service_terminate/3]).

-include_lib("cloudi_core/include/cloudi_logger.hrl").
-include_lib("cloudi_core/include/cloudi_service_api.hrl").

-define(DEFAULT_PURGE_ON_ERROR,              true).
        % Should the batch queue contents be purged when
        % a queue's currently running service fails
        % with an error and is unable to restart
        % (n.b., if a service configuration is unable
        %  to start (initialization fails) the queue is
        %  always purged with the error logged).
        % Any termination of any process (including restarts)
        % due to an error (Reason is not {shutdown, _} or shutdown)
        % will cause a purge when the service terminates.
-define(DEFAULT_QUEUES,                        []).
        % List of {QueueName, Configs} to be used for services_add
-define(DEFAULT_QUEUE_DEPENDENCIES,            []).
        % List of {QueueName, list(QueueNameDependency)} to represent
        % queue dependencies for providing runtime precedence.
        % If QueueName has a service terminate successfully,
        % each QueueNameDependency will be checked to ensure they have
        % no services executing or queued to be executed in the future
        % before starting the next queued QueueName service.
-define(DEFAULT_SUSPEND_DEPENDANTS,          true).
        % If a dependant (QueueName in the queue_dependencies) is already
        % running, should the service be suspended
        % (when QueueNameDependency is created) and resumed later.
-define(DEFAULT_QUEUES_STATIC,              false).
        % Disable dynamic modifications to the queues
        % (disables the external interface).
        % If queues_static is set to true,
        % stop_when_done must also be set to true.
-define(DEFAULT_STOP_WHEN_DONE,             false).
        % If queues contains entries, cause the
        % cloudi_service_api_batch service to stop successfully
        % once all queued service configurations have finished executing.

-record(queue,
    {
        count
            :: non_neg_integer(),
        data
            :: queue:queue(),
        service_id = undefined
            :: undefined | cloudi_service_api:service_id(),
        suspended = false
            :: boolean(),
        timeout_init = undefined
            :: undefined |
               cloudi_service_api:timeout_initialize_value_milliseconds(),
        terminate = false
            :: boolean(),
        terminate_timer = undefined
            :: undefined | reference(),
        terminate_purge = false
            :: boolean()
    }).

-record(state,
    {
        service
            :: cloudi_service:source(),
        purge_on_error
            :: boolean(),
        stop_when_done
            :: boolean(),
        suspend_dependants
            :: boolean(),
        dependencies
            :: trie:trie(), % name -> dependency name list
        dependants
            :: trie:trie(), % dependency name -> name list
        queue_count = 0
            :: non_neg_integer(),
        queues = trie:new()
            :: trie:trie() % queue name -> queue
    }).

-define(NAME_BATCH, "batch").
-define(FORMAT_ERLANG, "erl").
-define(FORMAT_JSON, "json").
-define(TIMEOUT_DELTA, 100). % milliseconds
-define(TERMINATE_INTERVAL, 500). % milliseconds

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

-type agent() :: cloudi:agent().
-type service_name() :: cloudi:service_name().
-type service_configuration() ::
    cloudi_service_api:service_internal() |
    cloudi_service_api:service_external() |
    cloudi_service_api:service_proplist().
-type service_configurations() ::
    nonempty_list(service_configuration()).
-type timeout_period() :: cloudi:timeout_period().
-type module_response(Result) ::
    {{ok, Result}, NewAgent :: agent()} |
    {{error, cloudi:error_reason()}, NewAgent :: agent()}.

-spec queue(Agent :: agent(),
            Prefix :: service_name(),
            QueueName :: nonempty_string()) ->
    module_response({ok, list(service_configuration())} |
                    {error, not_found}).

queue(Agent, Prefix, [I | _] = QueueName)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue, QueueName}).

-spec queue(Agent :: agent(),
            Prefix :: service_name(),
            QueueName :: nonempty_string(),
            Timeout :: timeout_period()) ->
    module_response({ok, list(service_configuration())} |
                    {error, not_found}).

queue(Agent, Prefix, [I | _] = QueueName, Timeout)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue, QueueName}, Timeout).

-spec queue_clear(Agent :: agent(),
                  Prefix :: service_name(),
                  QueueName :: nonempty_string()) ->
    module_response(ok | {error, not_found}).

queue_clear(Agent, Prefix, [I | _] = QueueName)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue_clear, QueueName}).

-spec queue_clear(Agent :: agent(),
                  Prefix :: service_name(),
                  QueueName :: nonempty_string(),
                  Timeout :: timeout_period()) ->
    module_response(ok | {error, not_found}).

queue_clear(Agent, Prefix, [I | _] = QueueName, Timeout)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue_clear, QueueName}, Timeout).

-spec queue_suspend(Agent :: agent(),
                    Prefix :: service_name(),
                    QueueName :: nonempty_string()) ->
    module_response(ok | {error, not_found}).

queue_suspend(Agent, Prefix, [I | _] = QueueName)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue_suspend, QueueName}).

-spec queue_suspend(Agent :: agent(),
                    Prefix :: service_name(),
                    QueueName :: nonempty_string(),
                    Timeout :: timeout_period()) ->
    module_response(ok | {error, not_found}).

queue_suspend(Agent, Prefix, [I | _] = QueueName, Timeout)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue_suspend, QueueName}, Timeout).

-spec queue_resume(Agent :: agent(),
                   Prefix :: service_name(),
                   QueueName :: nonempty_string()) ->
    module_response(ok | {error, not_found}).

queue_resume(Agent, Prefix, [I | _] = QueueName)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue_resume, QueueName}).

-spec queue_resume(Agent :: agent(),
                   Prefix :: service_name(),
                   QueueName :: nonempty_string(),
                   Timeout :: timeout_period()) ->
    module_response(ok | {error, not_found}).

queue_resume(Agent, Prefix, [I | _] = QueueName, Timeout)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {queue_resume, QueueName}, Timeout).

-spec services_add(Agent :: agent(),
                   Prefix :: service_name(),
                   QueueName :: nonempty_string(),
                   Configs :: service_configurations()) ->
    module_response(CountQueued :: non_neg_integer() | {error, purged}).

services_add(Agent, Prefix, [I | _] = QueueName, [_ | _] = Configs)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {services_add, QueueName, Configs}).

-spec services_add(Agent :: agent(),
                   Prefix :: service_name(),
                   QueueName :: nonempty_string(),
                   Configs :: service_configurations(),
                   Timeout :: timeout_period()) ->
    module_response(CountQueued :: non_neg_integer() | {error, purged}).

services_add(Agent, Prefix, [I | _] = QueueName, [_ | _] = Configs, Timeout)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {services_add, QueueName, Configs}, Timeout).

-spec services_remove(Agent :: agent(),
                      Prefix :: service_name(),
                      QueueName :: nonempty_string()) ->
    module_response(ok | {error, not_found}).

services_remove(Agent, Prefix, [I | _] = QueueName)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {services_remove, QueueName}).

-spec services_remove(Agent :: agent(),
                      Prefix :: service_name(),
                      QueueName :: nonempty_string(),
                      Timeout :: timeout_period()) ->
    module_response(ok | {error, not_found}).

services_remove(Agent, Prefix, [I | _] = QueueName, Timeout)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {services_remove, QueueName}, Timeout).

-spec services_restart(Agent :: agent(),
                       Prefix :: service_name(),
                       QueueName :: nonempty_string()) ->
    module_response(ok | {error, not_found | not_running}).

services_restart(Agent, Prefix, [I | _] = QueueName)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {services_restart, QueueName}).

-spec services_restart(Agent :: agent(),
                       Prefix :: service_name(),
                       QueueName :: nonempty_string(),
                       Timeout :: timeout_period()) ->
    module_response(ok | {error, not_found | not_running}).

services_restart(Agent, Prefix, [I | _] = QueueName, Timeout)
    when is_integer(I) ->
    cloudi:send_sync(Agent, Prefix ++ ?NAME_BATCH,
                     {services_restart, QueueName}, Timeout).

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_service
%%%------------------------------------------------------------------------

cloudi_service_init(Args, Prefix, _Timeout, Dispatcher) ->
    Defaults = [
        {purge_on_error,               ?DEFAULT_PURGE_ON_ERROR},
        {queues,                       ?DEFAULT_QUEUES},
        {queue_dependencies,           ?DEFAULT_QUEUE_DEPENDENCIES},
        {suspend_dependants,           ?DEFAULT_SUSPEND_DEPENDANTS},
        {queues_static,                ?DEFAULT_QUEUES_STATIC},
        {stop_when_done,               ?DEFAULT_STOP_WHEN_DONE}],
    [PurgeOnError, QueuesList, QueueDependenciesList, SuspendDependants,
     QueuesStatic, StopWhenDone] = cloudi_proplists:take_values(Defaults, Args),
    true = is_boolean(PurgeOnError),
    true = is_boolean(SuspendDependants),
    true = is_boolean(QueuesStatic),
    true = is_boolean(StopWhenDone),
    false = cloudi_service_name:pattern(Prefix),
    1 = cloudi_service:process_count_max(Dispatcher),
    Service = cloudi_service:self(Dispatcher),
    {Dependencies,
     Dependants} = batch_queue_dependencies(QueueDependenciesList),
    case QueuesList of
        [] ->
            false = QueuesStatic,
            false = StopWhenDone,
            ok;
        [_ | _] ->
            Service ! {init, QueuesList},
            ok
    end,
    if
        QueuesStatic =:= true ->
            true = StopWhenDone,
            ok;
        QueuesStatic =:= false ->
            % HTTP method safe/idempotent properties
            % are in relation to the queue data kept by the
            % cloudi_service_api_batch service,
            % not the state of the services executing with the
            % cloudi_service_api_batch logic
            % (e.g., services_restart is a GET).
            cloudi_service:subscribe(Dispatcher, ?NAME_BATCH),
            Interface = [{"queue", "/get"},
                         {"queue_clear", "/delete"},
                         {"queue_suspend", "/get"},
                         {"queue_resume", "/get"},
                         {"services_add", "/post"},
                         {"services_remove", "/delete"},
                         {"services_restart", "/get"}],
            Suffixes = lists:flatmap(fun({MethodName, FormatSuffix}) ->
                lists:flatmap(fun(Format) ->
                    FormatName = "/?/" ++ MethodName ++ "." ++ Format,
                    [FormatName,
                     FormatName ++ FormatSuffix]
                end, [?FORMAT_ERLANG, ?FORMAT_JSON])
            end, Interface),
            lists:foreach(fun(Suffix) ->
                cloudi_service:subscribe(Dispatcher, ?NAME_BATCH ++ Suffix)
            end, Suffixes)
    end,
    {ok, #state{service = Service,
                purge_on_error = PurgeOnError,
                stop_when_done = StopWhenDone,
                suspend_dependants = SuspendDependants,
                dependencies = Dependencies,
                dependants = Dependants}}.

cloudi_service_handle_request(_RequestType, Name, Pattern,
                              _RequestInfo, Request,
                              _Timeout, _Priority, _TransId, _Source,
                              State, _Dispatcher) ->
    {Response,
     StateNew} = case cloudi_service_name:parse_with_suffix(Name, Pattern) of
        {[], _} ->
            case Request of
                {queue, QueueName} ->
                    batch_queue_list(QueueName, State);
                {queue_clear, QueueName} ->
                    batch_queue_clear(QueueName, State);
                {queue_suspend, QueueName} ->
                    service_suspend(QueueName, State);
                {queue_resume, QueueName} ->
                    service_resume(QueueName, State);
                {services_add, QueueName, Configs} ->
                    batch_queue_add(QueueName, Configs, State);
                {services_remove, QueueName} ->
                    batch_queue_remove(QueueName, State);
                {services_restart, QueueName} ->
                    batch_queue_restart(QueueName, State)
            end;
        {[QueueName], "/" ++ MethodSuffix} ->
            MethodFormat = cloudi_string:beforel($/, MethodSuffix, input),
            {MethodName, Format} = cloudi_string:splitr($., MethodFormat),
            case MethodName of
                "queue" ->
                    external_format_to(Format, queue,
                                       batch_queue_list(QueueName, State));
                "queue_clear" ->
                    external_format_to(Format, queue_clear,
                                       batch_queue_clear(QueueName, State));
                "queue_suspend" ->
                    external_format_to(Format, queue_suspend,
                                       service_suspend(QueueName, State));
                "queue_resume" ->
                    external_format_to(Format, queue_resume,
                                       service_resume(QueueName, State));
                "services_add" ->
                    Configs = external_format_from(Format, services_add,
                                                   Request),
                    external_format_to(Format, services_add,
                                       batch_queue_add(QueueName,
                                                       Configs, State));
                "services_remove" ->
                    external_format_to(Format, services_remove,
                                       batch_queue_remove(QueueName, State));
                "services_restart" ->
                    external_format_to(Format, services_restart,
                                       batch_queue_restart(QueueName, State))
            end
    end,
    {reply, Response, StateNew}.

cloudi_service_handle_info({init, QueuesList},
                           State, _Dispatcher) ->
    {noreply, batch_queue_adds(QueuesList, State)};
cloudi_service_handle_info({aspects_init_after, QueueName, TimeoutInit},
                           State, _Dispatcher) ->
    {noreply, running_init(QueueName, TimeoutInit, State)};
cloudi_service_handle_info({aspects_terminate_before,
                            QueueName, Reason, TimeoutTerminate},
                           State, _Dispatcher) ->
    {noreply, running_terminate(QueueName, Reason, TimeoutTerminate, State)};
cloudi_service_handle_info({terminate, QueueName, Timeout},
                           State, _Dispatcher) ->
    {noreply, running_stopping(QueueName, Timeout, State)};
cloudi_service_handle_info({terminated, QueueName},
                           #state{queues = Queues} = State, _Dispatcher) ->
    Queue = trie:fetch(QueueName, Queues),
    case running_stopped(Queue, QueueName, State) of
        #state{stop_when_done = true,
               queue_count = 0} = StateNew ->
            {stop, shutdown, StateNew};
        StateNew ->
            {noreply, StateNew}
    end.

cloudi_service_terminate(_Reason, _Timeout, _State) ->
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

batch_queue_list(QueueName,
                 #state{queues = Queues} = State) ->
    case trie:find(QueueName, Queues) of
        {ok, #queue{data = Data}} ->
            {{ok, queue:to_list(Data)}, State};
        error ->
            {{error, not_found}, State}
    end.

batch_queue_clear(QueueName,
                  #state{queues = Queues} = State) ->
    case trie:find(QueueName, Queues) of
        {ok, #queue{service_id = ServiceId} = Queue} ->
            StateNew = if
                is_binary(ServiceId) ->
                    QueueNew = Queue#queue{count = 0,
                                           data = queue:new()},
                    QueuesNew = trie:store(QueueName,
                                                    QueueNew, Queues),
                    State#state{queues = QueuesNew};
                ServiceId =:= undefined ->
                    batch_queue_erase(QueueName, State)
            end,
            {ok, StateNew};
        error ->
            {{error, not_found}, State}
    end.

service_suspend(QueueName,
                #state{queues = Queues} = State) ->
    case trie:find(QueueName, Queues) of
        {ok, #queue{service_id = ServiceId}} ->
            _ = if
                is_binary(ServiceId) ->
                    cloudi_service_api:services_suspend([ServiceId], infinity);
                ServiceId =:= undefined ->
                    ok
            end,
            {ok, State};
        error ->
            {{error, not_found}, State}
    end.

service_resume(QueueName,
               #state{queues = Queues} = State) ->
    case trie:find(QueueName, Queues) of
        {ok, #queue{service_id = ServiceId}} ->
            _ = if
                is_binary(ServiceId) ->
                    cloudi_service_api:services_resume([ServiceId], infinity);
                ServiceId =:= undefined ->
                    ok
            end,
            {ok, State};
        error ->
            {{error, not_found}, State}
    end.

batch_queue_add(QueueName, Configs,
                #state{queues = Queues} = State) ->
    case trie:find(QueueName, Queues) of
        {ok, #queue{count = Count,
                    data = Data} = Queue} ->
            CountNew = Count + length(Configs),
            DataNew = queue:join(Data, queue:from_list(Configs)),
            QueueNew = Queue#queue{count = CountNew,
                                   data = DataNew},
            QueuesNew = trie:store(QueueName, QueueNew, Queues),
            {CountNew,
             State#state{queues = QueuesNew}};
        error ->
            case batch_queue_suspended(QueueName, State) of
                true ->
                    Count = length(Configs),
                    Data = queue:from_list(Configs),
                    Queue = #queue{count = Count,
                                   data = Data,
                                   suspended = true},
                    QueuesNew = trie:store(QueueName, Queue, Queues),
                    {Count,
                     State#state{queues = QueuesNew}};
                false ->
                    StateNew = batch_queue_suspend_dependants(QueueName, State),
                    batch_queue_run_new(QueueName, Configs, StateNew)
            end
    end.

batch_queue_remove(QueueName,
                   #state{queues = Queues} = State) ->
    case trie:find(QueueName, Queues) of
        {ok, #queue{service_id = ServiceId}} ->
            _ = if
                is_binary(ServiceId) ->
                    cloudi_service_api:services_remove([ServiceId], infinity);
                ServiceId =:= undefined ->
                    ok
            end,
            {ok, batch_queue_erase(QueueName, State)};
        error ->
            {{error, not_found}, State}
    end.

batch_queue_restart(QueueName,
                    #state{queues = Queues} = State) ->
    Result = case trie:find(QueueName, Queues) of
        {ok, #queue{service_id = ServiceId}} ->
            if
                is_binary(ServiceId) ->
                    case cloudi_service_api:
                         services_restart([ServiceId], infinity) of
                        ok ->
                            ok;
                        {error, {service_not_found, ServiceId}} ->
                            {error, not_running}
                    end;
                ServiceId =:= undefined ->
                    {error, not_running}
            end;
        error ->
            {error, not_found}
    end,
    {Result, State}.

batch_queue_erase(QueueName,
                  #state{queue_count = QueueCount,
                         queues = Queues} = State) ->
    QueuesNew = trie:erase(QueueName, Queues),
    batch_queue_resume(QueueName,
                       State#state{queue_count = QueueCount - 1,
                                   queues = QueuesNew}).

batch_queue_resume(QueueNameDependency,
                   #state{dependants = Dependants} = State) ->
    case trie:find(QueueNameDependency, Dependants) of
        {ok, QueueNameList} ->
            batch_queue_resume_list(QueueNameList, State);
        error ->
            State
    end.

batch_queue_resume_list([], State) ->
    State;
batch_queue_resume_list([QueueName | QueueNameList],
                         #state{queues = Queues} = State) ->
    StateNew = case trie:find(QueueName, Queues) of
        {ok, #queue{suspended = Suspended} = Queue} ->
            if
                Suspended =:= true ->
                    case batch_queue_suspended(QueueName, State) of
                        true ->
                            State;
                        false ->
                            batch_queue_run_old(Queue, QueueName, State)
                    end;
                Suspended =:= false ->
                    State
            end;
        error ->
            State
    end,
    batch_queue_resume_list(QueueNameList, StateNew).

batch_queue_suspend_dependants(_,
                               #state{suspend_dependants = false} = State) ->
    State;
batch_queue_suspend_dependants(QueueNameDependency,
                               #state{dependants = Dependants} = State) ->
    case trie:find(QueueNameDependency, Dependants) of
        {ok, QueueNameList} ->
            batch_queue_suspend_list(QueueNameList, State);
        error ->
            State
    end.

batch_queue_suspend_list([], State) ->
    State;
batch_queue_suspend_list([QueueName | QueueNameList],
                          #state{queues = Queues} = State) ->
    StateNew = case trie:find(QueueName, Queues) of
        {ok, #queue{} = Queue} ->
            batch_queue_suspend(QueueName, Queue, State);
        error ->
            State
    end,
    batch_queue_suspend_list(QueueNameList, StateNew).

batch_queue_suspend(QueueName,
                    #queue{service_id = ServiceId,
                           suspended = false} = Queue,
                    #state{queues = Queues} = State)
    when is_binary(ServiceId) ->
    case cloudi_service_api:services_suspend([ServiceId], infinity) of
        ok ->
            QueueNew = Queue#queue{suspended = true},
            QueuesNew = trie:store(QueueName, QueueNew, Queues),
            State#state{queues = QueuesNew};
        {error, {service_not_found, ServiceId}} ->
            State
    end;
batch_queue_suspend(_, _, State) ->
    State.

batch_queue_suspended(QueueName,
                      #state{dependencies = Dependencies,
                             queues = Queues}) ->
    case trie:find(QueueName, Dependencies) of
        {ok, QueueNameDependencyList} ->
            batch_queue_suspended_by_dependency(QueueNameDependencyList,
                                                Queues);
        error ->
            false
    end.

batch_queue_suspended_by_dependency([], _) ->
    false;
batch_queue_suspended_by_dependency([QueueNameDependency |
                                     QueueNameDependencyList],
                                    Queues) ->
    case trie:is_key(QueueNameDependency, Queues) of
        true ->
            true;
        false ->
            batch_queue_suspended_by_dependency(QueueNameDependencyList,
                                                Queues)
    end.

batch_queue_dependencies(QueueDependenciesList) ->
    {Dependencies,
     _Dependants} = Result = batch_queue_dependencies(QueueDependenciesList,
                                                      trie:new(),
                                                      trie:new()),
    true = batch_queue_dependencies_acyclic(QueueDependenciesList,
                                            Dependencies),
    Result.

batch_queue_dependencies([], Dependencies, Dependants) ->
    {Dependencies, Dependants};
batch_queue_dependencies([{QueueName, QueueNameDependencyList} |
                          QueueDependenciesList],
                         Dependencies, Dependants) ->
    true = is_integer(hd(QueueName)),
    false = cloudi_service_name:pattern(QueueName),
    false = trie:is_key(QueueName, Dependencies),
    batch_queue_dependencies(QueueDependenciesList,
                             trie:store(QueueName,
                                                 QueueNameDependencyList,
                                                 Dependencies),
                             batch_queue_dependants(QueueNameDependencyList,
                                                    Dependants, QueueName)).

batch_queue_dependencies_acyclic([], _) ->
    true;
batch_queue_dependencies_acyclic([{QueueName, QueueNameDependencyList} |
                                  QueueDependenciesList],
                                 Dependencies) ->
    case batch_queue_dependencies_acyclic_path(QueueNameDependencyList,
                                               QueueName,
                                               Dependencies) of
        true ->
            batch_queue_dependencies_acyclic(QueueDependenciesList,
                                             Dependencies);
        false ->
            false
    end.

batch_queue_dependencies_acyclic_path([], _, _) ->
    true;
batch_queue_dependencies_acyclic_path([QueueName | _],
                                      QueueName, _) ->
    false;
batch_queue_dependencies_acyclic_path([QueueNameDependency |
                                       QueueNameDependencyList],
                                      QueueName, Dependencies) ->
    Acyclic = case trie:find(QueueNameDependency, Dependencies) of
        {ok, L} ->
            batch_queue_dependencies_acyclic_path(L, QueueName, Dependencies);
        error ->
            true
    end,
    if
        Acyclic =:= true ->
            batch_queue_dependencies_acyclic_path(QueueNameDependencyList,
                                                  QueueName, Dependencies);
        Acyclic =:= false ->
            false
    end.

batch_queue_dependants([], Dependants, _) ->
    Dependants;
batch_queue_dependants([QueueNameDependency | QueueNameDependencyList],
                       Dependants, QueueName) ->
    true = is_integer(hd(QueueNameDependency)),
    false = cloudi_service_name:pattern(QueueNameDependency),
    DependencyListNew = case trie:find(QueueNameDependency,
                                                Dependants) of
        {ok, DependencyList} ->
            [QueueName | DependencyList];
        error ->
            [QueueName]
    end,
    batch_queue_dependants(QueueNameDependencyList,
                           trie:store(QueueNameDependency,
                                               DependencyListNew, Dependants),
                           QueueName).

batch_queue_adds([], State) ->
    State;
batch_queue_adds([{QueueName, Configs} | QueuesList], State) ->
    true = is_integer(hd(QueueName)),
    false = cloudi_service_name:pattern(QueueName),
    {_, StateNew} = batch_queue_add(QueueName, Configs, State),
    batch_queue_adds(QueuesList, StateNew).

external_format_from(?FORMAT_ERLANG, Method, Request) ->
    cloudi_service_api_requests:from_erl(Method, Request);
external_format_from(?FORMAT_JSON, Method, Request) ->
    cloudi_service_api_requests:from_json(Method, Request).

external_format_to(?FORMAT_ERLANG, Method, {Response, State}) ->
    {convert_term_to_erlang(Response, Method), State};
external_format_to(?FORMAT_JSON, Method, {Response, State}) ->
    {convert_term_to_json(Response, Method), State}.

running_init(QueueName, TimeoutInit,
             #state{queues = Queues} = State) ->
    Queue = trie:fetch(QueueName, Queues),
    #queue{terminate_timer = TerminateTimer} = Queue,
    if
        is_reference(TerminateTimer) ->
            ok = erlang:cancel_timer(TerminateTimer,
                                     [{async, true}, {info, false}]);
        TerminateTimer =:= undefined ->
            ok
    end,
    QueueNew = Queue#queue{timeout_init = TimeoutInit,
                           terminate = false,
                           terminate_timer = undefined},
    State#state{queues = trie:store(QueueName, QueueNew, Queues)}.

running_terminate(QueueName, Reason, TimeoutTerminate,
                  #state{service = Service,
                         purge_on_error = PurgeOnError,
                         queues = Queues} = State) ->
    TerminatePurge = if
        PurgeOnError =:= true ->
            case Reason of
                {shutdown, _} ->
                    false;
                shutdown ->
                    false;
                _ ->
                    true
            end;
        PurgeOnError =:= false ->
            false
    end,
    case trie:find(QueueName, Queues) of
        {ok, #queue{terminate = true,
                    terminate_purge = TerminatePurgeOld} = Queue} ->
            TerminatePurgeNew = TerminatePurge or TerminatePurgeOld,
            QueueNew = Queue#queue{terminate_purge = TerminatePurgeNew},
            State#state{queues = trie:store(QueueName,
                                                     QueueNew, Queues)};
        {ok, #queue{timeout_init = TimeoutInit,
                    terminate = false,
                    terminate_purge = TerminatePurgeOld} = Queue} ->
            Timeout = TimeoutTerminate + TimeoutInit + ?TIMEOUT_DELTA,
            TimeoutNew = Timeout - ?TERMINATE_INTERVAL,
            TerminateTimer = if
                TimeoutNew > 0 ->
                    erlang:send_after(?TERMINATE_INTERVAL, Service,
                                      {terminate, QueueName, TimeoutNew});
                true ->
                    erlang:send_after(Timeout, Service,
                                      {terminated, QueueName})
            end,
            TerminatePurgeNew = TerminatePurge or TerminatePurgeOld,
            QueueNew = Queue#queue{terminate = true,
                                   terminate_timer = TerminateTimer,
                                   terminate_purge = TerminatePurgeNew},
            State#state{queues = trie:store(QueueName,
                                                     QueueNew, Queues)};
        error ->
            State
    end.

running_stopping(QueueName, Timeout,
                 #state{service = Service,
                        queues = Queues} = State) ->
    Queue = trie:fetch(QueueName, Queues),
    #queue{service_id = ServiceId,
           terminate = Terminate} = Queue,
    Running = if
        is_binary(ServiceId) ->
            case cloudi_service_api:
                 service_subscriptions(ServiceId, infinity) of
                {error, not_found} ->
                    false;
                _ ->
                    true
            end;
        ServiceId =:= undefined ->
            false
    end,
    if
        Running =:= false ->
            running_stopped(Queue#queue{terminate = true,
                                        terminate_timer = undefined},
                            QueueName, State);
        Terminate =:= true ->
            TimeoutNew = Timeout - ?TERMINATE_INTERVAL,
            TerminateTimer = if
                TimeoutNew > 0 ->
                    erlang:send_after(?TERMINATE_INTERVAL, Service,
                                      {terminate, QueueName, TimeoutNew});
                true ->
                    erlang:send_after(Timeout, Service,
                                      {terminated, QueueName})
            end,
            QueueNew = Queue#queue{terminate_timer = TerminateTimer},
            State#state{queues = trie:store(QueueName,
                                                     QueueNew, Queues)};
        true ->
            % terminate_timer was cancelled after the message was queued
            State
    end.

running_stopped(#queue{terminate = false} = Queue, QueueName,
                #state{queues = Queues} = State) ->
    % terminate_timer was cancelled after the message was queued
    State#state{queues = trie:store(QueueName, Queue, Queues)};
running_stopped(#queue{terminate_purge = true}, QueueName, State) ->
    batch_queue_erase(QueueName, State);
running_stopped(#queue{count = Count,
                       terminate_purge = false} = Queue, QueueName,
                #state{queues = Queues} = State) ->
    if
        Count == 0 ->
            batch_queue_erase(QueueName, State);
        true ->
            case batch_queue_suspended(QueueName, State) of
                true ->
                    QueueNew = Queue#queue{service_id = undefined,
                                           suspended = true},
                    QueuesNew = trie:store(QueueName,
                                                    QueueNew, Queues),
                    State#state{queues = QueuesNew};
                false ->
                    batch_queue_run_old(Queue, QueueName, State)
            end
    end.

batch_queue_run_new(QueueName, [Config | ConfigsTail],
                    #state{service = Service,
                           queue_count = QueueCount,
                           queues = Queues} = State) ->
    case batch_queue_run(Config, QueueName, Service) of
        {ok, ServiceId} ->
            Count = length(ConfigsTail),
            Data = queue:from_list(ConfigsTail),
            QueueNew = #queue{count = Count,
                              data = Data,
                              service_id = ServiceId},
            QueuesNew = trie:store(QueueName, QueueNew, Queues),
            {Count,
             State#state{queue_count = QueueCount + 1,
                         queues = QueuesNew}};
        {error, _} ->
            {{error, purged}, State}
    end.

batch_queue_run_old(#queue{count = Count,
                           service_id = ServiceId,
                           suspended = true} = Queue, QueueName,
                    #state{queues = Queues} = State)
    when is_binary(ServiceId) ->
    case cloudi_service_api:services_resume([ServiceId], infinity) of
        ok ->
            QueueNew = Queue#queue{suspended = false},
            QueuesNew = trie:store(QueueName, QueueNew, Queues),
            State#state{queues = QueuesNew};
        {error, {service_not_found, ServiceId}} ->
            if
                Count == 0 ->
                    batch_queue_erase(QueueName, State);
                Count > 0 ->
                    batch_queue_run_old(Queue#queue{service_id = undefined},
                                        QueueName, State)
            end
    end;
batch_queue_run_old(#queue{count = Count,
                           data = Data} = Queue, QueueName,
                    #state{service = Service,
                           queues = Queues} = State) ->
    {{value, Config}, DataNew} = queue:out(Data),
    case batch_queue_run(Config, QueueName, Service) of
        {ok, ServiceId} ->
            QueueNew = Queue#queue{count = Count - 1,
                                   data = DataNew,
                                   service_id = ServiceId,
                                   suspended = false,
                                   terminate = false,
                                   terminate_timer = undefined},
            QueuesNew = trie:store(QueueName, QueueNew, Queues),
            State#state{queues = QueuesNew};
        {error, _} ->
            batch_queue_erase(QueueName, State)
    end.

batch_queue_run(Config, QueueName, Service) ->
    ConfigBatch = batch_queue_run_config(Config, QueueName, Service),
    case cloudi_service_api:services_add([ConfigBatch], infinity) of
        {ok, [ServiceId]} ->
            {ok, ServiceId};
        {error, Reason} = Error ->
            ?LOG_ERROR("config ~p~nfailure ~p purged \"~s\" queue",
                       [ConfigBatch, Reason, QueueName]),
            Error
    end.

batch_queue_run_config(#internal{options = Options} = ServiceConfig,
                       QueueName, Service) ->
    ServiceConfig#internal{options = add_options(internal, Options,
                                                 QueueName, Service)};
batch_queue_run_config(#external{options = Options} = ServiceConfig,
                       QueueName, Service) ->
    ServiceConfig#external{options = add_options(external, Options,
                                                 QueueName, Service)};
batch_queue_run_config([_ | _] = ServiceConfig, QueueName, Service) ->
    Type = case lists:keyfind(module, 1, ServiceConfig) of
        {_, _} ->
            internal;
        false ->
            external
    end,
    case lists:keytake(options, 1, ServiceConfig) of
        {value, {_, Options}, NextServiceConfig} ->
            [{options, add_options(Type, Options, QueueName, Service)} |
             NextServiceConfig];
        false ->
            [{options, add_options(Type, [], QueueName, Service)} |
             ServiceConfig]
    end.

add_options(Type, Options0, QueueName, Service) ->
    OptionsN = add_option(Type, aspects_init_after,
                          Options0, QueueName, Service),
    add_option(Type, aspects_terminate_before,
               OptionsN, QueueName, Service).

add_option(Type, Option, Options, QueueName, Service) ->
    Aspect = if
        Option =:= aspects_init_after ->
            if
                Type =:= internal ->
                    fun(_Args, _Prefix, Timeout, State, _Dispatcher) ->
                        Service ! {Option, QueueName, Timeout},
                        {ok, State}
                    end;
                Type =:= external ->
                    fun(_CommandLine, _Prefix, Timeout, State) ->
                        Service ! {Option, QueueName, Timeout},
                        {ok, State}
                    end
            end;
        Option =:= aspects_terminate_before ->
            fun(Reason, Timeout, State) ->
                Service ! {Option, QueueName, Reason, Timeout},
                {ok, State}
            end
    end,
    case lists:keytake(Option, 1, Options) of
        {value, {_, OptionL}, NextOptions} ->
            if
                Option =:= aspects_init_after ->
                    [{Option, [Aspect | OptionL]} | NextOptions];
                Option =:= aspects_terminate_before ->
                    [{Option, OptionL ++ [Aspect]} | NextOptions]
            end;
        false ->
            [{Option, [Aspect]} | Options]
    end.

convert_term_to_erlang({ok, QueueList}, queue) ->
    QueueListNew = cloudi_service_api_requests:to_data_erl_services(QueueList),
    convert_term_to_erlang_string({ok, QueueListNew});
convert_term_to_erlang(Result, _) ->
    convert_term_to_erlang_string(Result).

convert_term_to_erlang_string(Result) ->
    cloudi_string:format_to_binary("~p", [Result]).

convert_term_to_json(ok, _) ->
    json_encode([{<<"success">>, true}]);
convert_term_to_json({error, Reason}, _) ->
    ReasonBinary = cloudi_string:term_to_binary_compact(Reason),
    json_encode([{<<"success">>, false},
                 {<<"error">>, ReasonBinary}]);
convert_term_to_json({ok, QueueList}, Method)
    when Method =:= queue ->
    json_encode([{<<"success">>, true},
                 {erlang:atom_to_binary(Method, utf8),
                  cloudi_service_api_requests:
                  to_data_json_services(QueueList)}]);
convert_term_to_json(Term, Method) ->
    json_encode([{<<"success">>, true},
                 {erlang:atom_to_binary(Method, utf8), Term}]).

json_encode(Term) ->
    jsx:encode(Term, [{indent, 1}]).

