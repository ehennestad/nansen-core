function parts = parseVersion(text)
%parseVersion [major minor patch] of a MAJOR.MINOR.PATCH string, or [] when it is not one
    parts = [];
    if ~(ischar(text) && (isrow(text) || isempty(text))) && ~(isstring(text) && isscalar(text))
        return
    end
    tokens = regexp(char(text), '^(\d+)\.(\d+)\.(\d+)$', "tokens", "once");
    if ~isempty(tokens)
        parts = str2double(tokens);
    end
end
