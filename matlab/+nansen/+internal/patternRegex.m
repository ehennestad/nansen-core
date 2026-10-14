function regex = patternRegex(pattern, values)
%patternRegex A DSM file pattern with its {field} tokens replaced by the escaped values
    [tokens, literals] = regexp(char(pattern), "\{([A-Za-z_][A-Za-z0-9_]*)\}", "tokens", "split");
    regex = string(literals{1});
    for i = 1:numel(tokens)
        value = nansen.internal.getField(values, tokens{i}{1}, "");
        if nansen.internal.isMissingValue(value)
            value = "";
        end
        regex = regex + regexptranslate("escape", char(nansen.internal.formatToken(value))) + string(literals{i + 1});
    end
end
