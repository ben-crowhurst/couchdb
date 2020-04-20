% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(aegis_server_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("couch/include/couch_eunit.hrl").

-define(SERVER, aegis_server).
-define(DB, #{aegis => <<0:320>>, uuid => <<0:64>>}).
-define(VALUE, <<0:8192>>).
-define(ENCRYPTED, <<1:8, 0:320, 0:4096>>).
-define(TIMEOUT, 10000).



basic_test_() ->
    {
        foreach,
        fun setup/0,
        fun teardown/1,
        [
            {"cache unwrapped key on generate_key",
            {timeout, ?TIMEOUT, fun test_generate_key/0}},
            {"cache unwrapped key on encrypt",
            {timeout, ?TIMEOUT, fun test_encrypt/0}},
            {"cache unwrapped key on decrypt",
            {timeout, ?TIMEOUT, fun test_decrypt/0}},
            {"cache unwrapped key per database",
            {timeout, ?TIMEOUT, fun test_multibase/0}}
        ]
    }.


setup() ->
    Ctx = test_util:start_couch([fabric]),
    %% isolate aegis_key_cache from actual crypto
    meck:new([aegis_server, aegis_keywrap], [passthrough]),
    ok = meck:expect(aegis_keywrap, key_wrap, 2, <<0:320>>),
    ok = meck:expect(aegis_keywrap, key_unwrap, fun(_, _) ->
        %% build a line of the waiters
        timer:sleep(20),
        <<0:256>>
    end),
    ok = meck:expect(aegis_server, do_encrypt, fun(From, _, _, _, _) ->
        gen_server:reply(From, ?ENCRYPTED)
    end),
    ok = meck:expect(aegis_server, do_decrypt, fun(From, _, _, _, _) ->
        gen_server:reply(From, ?VALUE)
    end),
    Ctx.


teardown(Ctx) ->
    meck:unload(),
    test_util:stop_couch(Ctx).


test_generate_key() ->
    {ok, WrappedKey1} = aegis_server:generate_key(?DB),
    ?assertEqual(<<0:320>>, WrappedKey1),
    ?assertEqual(1, meck:num_calls(aegis_keywrap, key_wrap, 2)).


test_encrypt() ->
    ?assertEqual(0, meck:num_calls(aegis_keywrap, key_unwrap, 2)),
    ?assertEqual(0, meck:num_calls(aegis_server, do_encrypt, 5)),

    lists:foreach(fun(I) ->
        Encrypted = aegis_server:encrypt(?DB, <<I:64>>, ?VALUE),
        ?assertEqual(?ENCRYPTED, Encrypted)
    end, lists:seq(1, 12)),

    ?assertEqual(1, meck:num_calls(aegis_keywrap, key_unwrap, 2)),
    ?assertEqual(12, meck:num_calls(aegis_server, do_encrypt, 5)).


test_decrypt() ->
    ?assertEqual(0, meck:num_calls(aegis_keywrap, key_unwrap, 2)),
    ?assertEqual(0, meck:num_calls(aegis_server, do_encrypt, 5)),

    lists:foreach(fun(I) ->
        Decrypted = aegis_server:decrypt(?DB, <<I:64>>, ?ENCRYPTED),
        ?assertEqual(?VALUE, Decrypted)
    end, lists:seq(1, 12)),

    ?assertEqual(1, meck:num_calls(aegis_keywrap, key_unwrap, 2)),
    ?assertEqual(12, meck:num_calls(aegis_server, do_decrypt, 5)).


test_multibase() ->
    ?assertEqual(0, meck:num_calls(aegis_keywrap, key_unwrap, 2)),
    ?assertEqual(0, meck:num_calls(aegis_server, do_encrypt, 5)),

    lists:foreach(fun(I) ->
        Db = ?DB#{aegis => <<I:320>>},
        lists:foreach(fun(J) ->
            Key = <<J:64>>,
            Out = aegis_server:encrypt(Db, Key, ?VALUE),
            ?assertEqual(?ENCRYPTED, Out),
            In = aegis_server:decrypt(Db, Key, Out),
            ?assertEqual(?VALUE, In)
        end, lists:seq(1, 10))
    end, lists:seq(1, 12)),

    ?assertEqual(12, meck:num_calls(aegis_keywrap, key_unwrap, 2)),
    ?assertEqual(120, meck:num_calls(aegis_server, do_encrypt, 5)),
    ?assertEqual(120, meck:num_calls(aegis_server, do_decrypt, 5)).



error_test_() ->
    {
        foreach,
        fun() ->
            Ctx = setup(),
            ok = meck:delete(aegis_keywrap, key_unwrap, 2),
            ok = meck:expect(aegis_keywrap, key_unwrap, 2, fail),
            Ctx
        end,
        fun teardown/1,
        [
            {"return error when unwrap fail on encrypt",
            {timeout, ?TIMEOUT, fun test_encrypt_error/0}},
            {"return error when unwrap fail on decrypt",
            {timeout, ?TIMEOUT, fun test_decrypt_error/0}}
        ]
    }.


test_encrypt_error() ->
    Reply = aegis_server:encrypt(?DB, <<1:64>>, ?VALUE),
    ?assertEqual({error, unwrap_failed}, Reply).


test_decrypt_error() ->
    Reply = aegis_server:decrypt(?DB, <<1:64>>, ?ENCRYPTED),
    ?assertEqual({error, unwrap_failed}, Reply).