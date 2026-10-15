function name = functionName(path)
%functionName The MATLAB name of a .m file: its package folders (+name) and its name
%
%   nansen.legacy.functionName("code/+RatNav/+sessionmethod/+process/countTrials.m")
%   is "RatNav.sessionmethod.process.countTrials". As Python's
%   nansen.legacymethods.function_name.
    arguments
        path (1,1) string
    end
    parts = reshape(split(replace(path, "\", "/"), "/"), 1, []);
    stem = regexprep(parts(end), "\.m$", "");
    packages = strings(1, 0);
    for k = numel(parts) - 1:-1:1
        if ~startsWith(parts(k), "+") || strlength(parts(k)) < 2
            break
        end
        packages = [extractAfter(parts(k), 1), packages]; %#ok<AGROW>
    end
    name = strjoin([packages, stem], ".");
end
