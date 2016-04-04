-module(db_migration).
-export([start_mnesia/0, transform/2, get_base_revision/0,
	 create_migration_file/1, init_migrations/0,
	 get_next_revision/1, get_current_head/1, get_current_head/0,
	 read_config/0, create_migration_file/0,
	 find_pending_migrations/0, apply_upgrades/0,
	 get_revision_tree/0, append_revision_tree/2,
	 get_applied_head/0, update_head/1
	]).

-define(URNAME, user).
-define(TABLE, schema_migrations).
-define(BaseDir, "/home/gaurav/project/mnesia_migrate/migrations/").
-define(ProjDir, "/home/gaurav/project/mnesia_migrate/").

-record(schema_migrations, {curr_head=null, extra_info=null}).

read_config() ->
    Val = case application:get_env(mnesia_migrate, migration_dir, "~/project/mnesia_migrate/migrations/") of
        {ok, Value} -> Value;
        Def -> Def
	end,
    io:format("migration_dir: ~p~n", [Val]).

start_mnesia() ->
	mnesia:start().

init_migrations() ->
    case lists:member(?TABLE, mnesia:system_info(tables)) of
        true ->
            ok;
        false ->
            io:format("Table schema_migration not found, creating...~n", []),
            Attr = [{ram_copies, []}, {disk_copies, []} ,{attributes, record_info(fields, schema_migrations)}],
            case mnesia:create_table(?TABLE, Attr) of
                {atomic, ok}      -> io:format(" => created~n", []);
                {aborted, Reason} -> io:format("mnesia create table error: ~p~n", [Reason]),
				     throw({error, Reason})
            end
    end.

transform(_Old_struct, _New_struct) ->
	ok.

%fetch_all_changed_tables() ->
    %set_path("/home/gaurav/project/butler_server/src"),
%    Models = models:all(),
%    Tabletomigrate = [TableName || {TableName, Options} <- Models , proplists:get_value(attributes, Options) /= mnesia:table_info(TableName, attributes)],
%    io:fwrite("Tables needing migration : ~p~n", [Tabletomigrate]),
%    Tabletomigrate.

get_base_revision() ->
    Modulelist = filelib:wildcard("migrations/*.beam"),
    Res = lists:filter(fun(Filename) ->
        Modulename = list_to_atom(filename:basename(Filename, ".beam")),
        string:equal(Modulename:get_prev_rev(),none)
    end,
    Modulelist),
    BaseModuleName = list_to_atom(filename:basename(Res, ".beam")),
    io:fwrite("Base Rev file is ~p~n", [BaseModuleName]),
    case Res of
        [] -> none;
	_ -> BaseModuleName:get_current_rev()
    end.


get_next_revision(RevId) ->
    Modulelist = filelib:wildcard("migrations/*.beam"),
    Res = lists:filter(fun(Filename) ->
        Modulename = list_to_atom(filename:basename(Filename, ".beam")),
        OldrevId = Modulename:get_prev_rev(),
        string:equal(OldrevId, RevId)
    end,
    Modulelist),
    %io:fwrite("Base Rev: ~p Next Rev ~p~n", [RevId,Res]),
    case Res of
    [] -> [];
    _ -> ModuleName = list_to_atom(filename:basename(Res, ".beam")), ModuleName:get_current_rev()
    end.

get_current_head(RevId) ->
    case get_next_revision(RevId) of
	[] -> RevId ;
        NextRevId -> get_current_head(NextRevId)
    end.

get_current_head() ->
    BaseRev = get_base_revision(),
    get_current_head(BaseRev).

create_migration_file(CommitMessage) ->
    erlydtl:compile('schema.template', migration_template),
    NewRevisionId = string:substr(uuid:to_string(uuid:uuid4()),1,8),
    OldRevisionId = get_current_head(),
    Filename = NewRevisionId ++ "_" ++ string:substr(CommitMessage, 1, 20) ,
    {ok, Data} = migration_template:render([{new_rev_id , NewRevisionId}, {old_rev_id, OldRevisionId},
					  {modulename, Filename}, {tabtomig, []},
					  {commitmessage, CommitMessage}]),
    file:write_file(?BaseDir ++ Filename ++ ".erl", Data).

create_migration_file() ->
    erlydtl:compile('schema.template', migration_template),
    NewRevisionId = "a" ++ string:substr(uuid:to_string(uuid:uuid4()),1,8),
    BaseRev = get_base_revision(),
    OldRevisionId = get_current_head(BaseRev),
    Filename = NewRevisionId ++ "_migration" ,
    {ok, Data} = migration_template:render([{new_rev_id , NewRevisionId}, {old_rev_id, OldRevisionId},
					  {modulename, Filename}, {tabtomig, []},
					  {commitmessage, "migration"}]),
    file:write_file(?BaseDir ++ Filename ++ ".erl", Data),
    io:format("New file created ~p~n", [Filename ++ ".erl"]).

get_revision_tree() ->
    BaseRev = get_base_revision(),
    List1 = [],
    RevList = append_revision_tree(List1, BaseRev),
    io:format("RevList ~p~n", [RevList]),
    RevList.

find_pending_migrations() ->
   % fetch current revision head from database
   AppliedHead = case get_applied_head() of
   none -> get_base_revision() ;
   Id -> Id
   end,
   List1 = [],
   RevList = append_revision_tree(List1, AppliedHead),
   io:format("Revisions needing migration : ~p~n", [RevList]),
   RevList.

apply_upgrades() ->
    RevList = find_pending_migrations(),
    lists:foreach(fun(RevId) -> ModuleName = list_to_atom(atom_to_list(RevId) ++ "_migration") , ModuleName:up() end, RevList),
    io:format("all upgrades successfully applied.~n"),
    %% update head in database
    update_head(lists:last(RevList)).


append_revision_tree(List1, RevId) ->
    case get_next_revision(RevId) of
        [] -> List1 ++ [RevId];
	NewRevId ->
		   List2 = List1 ++ [RevId],
	           append_revision_tree(List2, NewRevId)
    end.

get_applied_head() ->
	{atomic, KeyList} = mnesia:transaction(fun() -> mnesia:all_keys(schema_migrations) end),
	io:format("current applied head is : ~p~n", [hd(KeyList)]),
	hd(KeyList).

update_head(Head) ->
	mnesia:transaction(fun() -> mnesia:write(schema_migrations, #schema_migrations{curr_head = Head}, write) end).