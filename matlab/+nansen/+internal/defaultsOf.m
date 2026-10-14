function value = defaultsOf(schema)
%defaultsOf The default a JSON Schema gives: its own default, or a struct of its properties' defaults
    value = [];
    if ~isstruct(schema)
        return
    end
    if isfield(schema, "default")
        value = schema.default;
        return
    end
    if (isfield(schema, "type") && isequal(string(schema.type), "object")) || isfield(schema, "properties")
        value = struct();
        properties = nansen.internal.getField(schema, "properties", struct());
        for name = reshape(string(fieldnames(properties)), 1, [])
            sub = nansen.internal.defaultsOf(properties.(name));
            if ~(isnumeric(sub) && isempty(sub))
                value.(name) = sub;
            end
        end
    end
end
