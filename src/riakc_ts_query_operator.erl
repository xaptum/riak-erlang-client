-module(riakc_ts_query_operator).

-include_lib("riak_pb/include/riak_pb.hrl").
-include_lib("riak_pb/include/riak_kv_pb.hrl").

-export([serialize/2,
         deserialize/1]).

serialize(QueryText, Interpolations) ->
    Content = #tsinterpolation{
                 base = QueryText,
                 interpolations = serialize_interpolations(Interpolations)},
    #tsqueryreq{query = Content}.

serialize_interpolations(Interpolations) ->
    serialize_interpolations(Interpolations, []).

serialize_interpolations([], SerializedInterps) ->
    SerializedInterps;
serialize_interpolations([{Key, Value} | RemainingInterps],
                         SerializedInterps) ->
    UpdatedInterps = [#rpbpair{key=Key, value=Value} | SerializedInterps],
    serialize_interpolations(RemainingInterps, UpdatedInterps).

deserialize(#tsqueryresp{columns = Columns_, rows = Rows_}) ->
    Columns = [C || #tscolumndescription{name = C} <- Columns_],
    Rows = [from_cells(CC, []) || #tsrow{cells = CC} <- Rows_],
    {Columns, Rows}.

from_cells([], Acc) ->
    lists:reverse(Acc);
from_cells([#tscell{binary_value    = Bin,
                    integer_value   = undefined,
                    numeric_value   = undefined,
                    timestamp_value = undefined,
                    boolean_value   = undefined,
                    set_value       = [],
                    map_value       = undefined} | T], Acc) ->
    from_cells(T, [Bin | Acc]);
from_cells([#tscell{binary_value    = undefined,
                    integer_value   = Int,
                    numeric_value   = undefined,
                    timestamp_value = undefined,
                    boolean_value   = undefined,
                    set_value       = [],
                    map_value       = undefined} | T], Acc) ->
    from_cells(T, [Int | Acc]);
from_cells([#tscell{binary_value    = undefined,
                    integer_value   = undefined,
                    numeric_value   = Num,
                    timestamp_value = undefined,
                    boolean_value   = undefined,
                    set_value       = [],
                    map_value       = undefined} | T], Acc) ->
    from_cells(T, [list_to_float(binary_to_list(Num)) | Acc]);
from_cells([#tscell{binary_value    = undefined,
                    integer_value   = undefined,
                    numeric_value   = undefined,
                    timestamp_value = Timestamp,
                    boolean_value   = undefined,
                    set_value       = [],
                    map_value       = undefined} | T], Acc) ->
    from_cells(T, [Timestamp | Acc]);
from_cells([#tscell{binary_value    = undefined,
                    integer_value   = undefined,
                    numeric_value   = undefined,
                    timestamp_value = undefined,
                    boolean_value   = Bool,
                    set_value       = [],
                    map_value       = undefined} | T], Acc) ->
    from_cells(T, [Bool | Acc]);
from_cells([#tscell{binary_value    = undefined,
                    integer_value   = undefined,
                    numeric_value   = undefined,
                    timestamp_value = undefined,
                    boolean_value   = undefined,
                    set_value       = Set,
                    map_value       = undefined} | T], Acc) ->
    from_cells(T, [Set | Acc]);
from_cells([#tscell{binary_value    = undefined,
                    integer_value   = undefined,
                    numeric_value   = undefined,
                    timestamp_value = undefined,
                    boolean_value   = undefined,
                    set_value       = [],
                    map_value       = Map} | T], Acc) ->
    from_cells(T, [Map | Acc]).