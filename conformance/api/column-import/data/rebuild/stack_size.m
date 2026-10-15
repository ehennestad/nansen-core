function result = stack_size(entity, options, context) %#ok<INUSD>
%stack_size A computed column's method of two columns, to import: the height and width of a session's stack
    result = struct("height", 512, "width", strlength(string(entity.Key.session_id)));
end
