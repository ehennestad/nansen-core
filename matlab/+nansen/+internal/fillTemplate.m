function text = fillTemplate(template, values, what)
%fillTemplate Replace {field} tokens with the entity's values; missing-value when one has none
    [tokens, literals] = regexp(char(template), "\{([A-Za-z_][A-Za-z0-9_]*)\}", "tokens", "split");
    text = string(literals{1});
    for i = 1:numel(tokens)
        name = tokens{i}{1};
        value = nansen.internal.getField(values, name, []);
        if nansen.internal.isMissingValue(value)
            nansen.internal.throwError("missing-value", "%s: '%s' has no value for this entity", what, name)
        end
        text = text + nansen.internal.formatToken(value) + string(literals{i + 1});
    end
end
