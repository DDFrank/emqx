%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_mod_acl_internal).

-behaviour(emqx_gen_mod).

-include("emqx.hrl").
-include("logger.hrl").

-export([load/1, unload/1]).

-export([all_rules/0]).

-export([check_acl/5, reload_acl/0]).

-define(ACL_RULE_TAB, emqx_acl_rule).

-define(FUNC(M, F, A), {M, F, A}).

-type(acl_rules() :: #{publish => [emqx_access_rule:rule()],
                       subscribe => [emqx_access_rule:rule()]}).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

load(_Env) ->
    Rules = load_rules_from_file(acl_file()),
    emqx_hooks:add('client.check_acl', ?FUNC(?MODULE, check_acl, [Rules]),  -1).

unload(_Env) ->
    Rules = load_rules_from_file(acl_file()),
    emqx_hooks:del('client.check_acl', ?FUNC(?MODULE, check_acl, [Rules])).

%% @doc Read all rules
-spec(all_rules() -> list(emqx_access_rule:rule())).
all_rules() ->
    load_rules_from_file(acl_file()).

%%------------------------------------------------------------------------------
%% ACL callbacks
%%------------------------------------------------------------------------------

load_rules_from_file(AclFile) ->
    case file:consult(AclFile) of
        {ok, Terms} ->
            Rules = [emqx_access_rule:compile(Term) || Term <- Terms],
            #{publish => lists:filter(fun(Rule) -> filter(publish, Rule) end, Rules),
              subscribe => lists:filter(fun(Rule) -> filter(subscribe, Rule) end, Rules)};
        {error, Reason} ->
            ?LOG(error, "[ACL_INTERNAL] Failed to read ~s: ~p", [AclFile, Reason]),
            #{}
    end.

filter(_PubSub, {allow, all}) ->
    true;
filter(_PubSub, {deny, all}) ->
    true;
filter(publish, {_AllowDeny, _Who, publish, _Topics}) ->
    true;
filter(_PubSub, {_AllowDeny, _Who, pubsub, _Topics}) ->
    true;
filter(subscribe, {_AllowDeny, _Who, subscribe, _Topics}) ->
    true;
filter(_PubSub, {_AllowDeny, _Who, _, _Topics}) ->
    false.

%% @doc Check ACL
-spec(check_acl(emqx_types:credentials(), emqx_types:pubsub(), emqx_topic:topic(),
                emqx_access_rule:acl_result(), acl_rules())
      -> {ok, allow} | {ok, deny} | ok).
check_acl(Credentials, PubSub, Topic, _AclResult, Rules) ->
    case match(Credentials, Topic, lookup(PubSub, Rules)) of
        {matched, allow} -> {ok, allow};
        {matched, deny}  -> {ok, deny};
        nomatch          -> ok
    end.

lookup(PubSub, Rules) ->
    maps:get(PubSub, Rules, []).

match(_Credentials, _Topic, []) ->
    nomatch;
match(Credentials, Topic, [Rule|Rules]) ->
    case emqx_access_rule:match(Credentials, Topic, Rule) of
        nomatch ->
            match(Credentials, Topic, Rules);
        {matched, AllowDeny} ->
            {matched, AllowDeny}
    end.

-spec(reload_acl() -> ok | {error, term()}).
reload_acl() ->
    try load_rules_from_file(acl_file()) of
        ok ->
            emqx_logger:info("Reload acl_file ~s successfully", [acl_file()]),
            ok;
        {error, Error} ->
            {error, Error}
    catch
        error:Reason:StackTrace ->
            ?LOG(error, "Reload acl failed. StackTrace: ~p", [StackTrace]),
            {error, Reason}
    end.

acl_file() ->
    emqx_config:get_env(acl_file).
