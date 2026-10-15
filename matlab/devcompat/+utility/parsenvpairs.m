function opt = parsenvpairs(def, vfun, varargin) %#ok<INUSL>
%parsenvpairs dev's utility.parsenvpairs: the defaults with the values given over them
%
%   opt = utility.parsenvpairs(def, vfun, varargin) takes a struct of
%   defaults and the values as a struct and/or name-value pairs (or a cell
%   of them, as a function passes its varargin on). Only names of def are
%   taken, and def's config fields (<name>_, the choices of name) are left
%   out, as dev's. dev's validation (vfun) is not done.
    if isempty(varargin)
        opt = def;
        return
    end
    if isscalar(varargin) && iscell(varargin{1})
        varargin = varargin{1};
    end
    names = fieldnames(def);
    keep = true(size(names));
    for i = 1:numel(names)
        keep(i) = ~(endsWith(names{i}, '_') && any(strcmp(names{i}(1:end - 1), names)));
    end
    names = names(keep);
    opt = struct();
    for i = 1:numel(names)
        opt.(names{i}) = def.(names{i});
    end
    k = 1;
    while k <= numel(varargin)
        item = varargin{k};
        if isstruct(item) && isscalar(item)
            given = fieldnames(item);
            for i = 1:numel(given)
                if any(strcmp(given{i}, names))
                    opt.(given{i}) = item.(given{i});
                end
            end
            k = k + 1;
        elseif (ischar(item) || (isstring(item) && isscalar(item))) && k < numel(varargin)
            if any(strcmp(char(item), names))
                opt.(char(item)) = varargin{k + 1};
            end
            k = k + 2;
        else
            k = k + 1;
        end
    end
end
