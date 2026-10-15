function result = runSessionMethod(input, options, context)
%runSessionMethod Run an imported NANSEN dev session method (legacySessionMethod) on one entity or on all at once
%
%   result = nansen.legacy.runSessionMethod(entity, options, context) is
%   what nansen.runMethod calls for a method whose document has
%   legacySessionMethod (context.Method is the method; input is an entity,
%   or a cell of them for a batch method). Each entity becomes a
%   nansen.legacy.SessionShim, dev's session object, and dev's code is
%   called as dev called it:
%
%   - a function as name(sessions, options), with no outputs;
%   - a class as name(sessions, options), then its run method (dev's
%     SessionMethod.run: runMethod, or main when it has no runMethod).
%
%   options are dev's defaults (the function's DefaultOptions attribute,
%   the class's getDefaultOptions) with the run's options over them, each
%   in the shape of dev's default (text as char, rows as rows, cells as
%   cells). The compatibility folder matlab/devcompat is put on the path:
%   it holds the parts of dev these methods call (nansen.session.SessionMethod,
%   nansen.OptionsManager, utility.parsenvpairs). Returns an empty struct.
    method = context.Method;
    if isempty(method) || ~isfield(method.Document, "legacySessionMethod")
        error("nansen:Legacy:NotASessionMethod", "runSessionMethod runs methods imported from NANSEN dev (legacySessionMethod)")
    end
    nansen.legacy.addCompatibility()
    name = string(method.Document.implementations.matlab);
    kind = string(method.Document.legacySessionMethod.kind);
    if iscell(input)
        entities = input;
    else
        entities = {input};
    end
    sessions = nansen.legacy.SessionShim(entities{1}, context);
    for i = 2:numel(entities)
        sessions = [sessions, nansen.legacy.SessionShim(entities{i}, context)]; %#ok<AGROW>
    end
    values = devOptions(devDefaults(name, kind), options);
    context.log("dev's %s on %s", name, strjoin(string(arrayfun(@(s) string(s.getDataId()), sessions, UniformOutput=false)), ", "));
    if kind == "class"
        instance = feval(name, sessions, values);   % with an output, so its constructor does not run it
        instance.run();
    else
        feval(name, sessions, values);
    end
    result = struct();
end

function defaults = devDefaults(name, kind)
    % dev's default options: a function's DefaultOptions attribute (it returns its attributes when called with
    % no inputs), a class's getDefaultOptions
    defaults = struct();
    try
        if kind == "class"
            defaults = feval(name + ".getDefaultOptions");
        else
            attributes = feval(name);
            defaults = nansen.internal.getField(attributes, "DefaultOptions", struct());
        end
    catch err
        warning("nansen:Legacy:NoDefaults", "dev's default options of %s could not be read (%s); the run's options are used", ...
            name, err.message)
    end
    if ~(isstruct(defaults) && isscalar(defaults))
        defaults = struct();
    end
end

function values = devOptions(defaults, options)
    % The run's options over dev's defaults, each in the shape of dev's default
    values = defaults;
    if ~(isstruct(options) && isscalar(options))
        return
    end
    for name = reshape(string(fieldnames(options)), 1, [])
        given = options.(name);
        if ~isfield(values, name)
            values.(name) = given;
            continue
        end
        default = values.(name);
        if isstruct(default) && isscalar(default) && isstruct(given) && isscalar(given)
            values.(name) = devOptions(default, given);
        else
            values.(name) = like(given, default);
        end
    end
end

function value = like(value, default)
    % A decoded JSON value in the shape of dev's default of it
    if ischar(default) && (isstring(value) || ischar(value))
        value = char(value);
    elseif isstring(default) && (isstring(value) || ischar(value))
        value = string(value);
    elseif iscell(default)
        if isempty(value)
            value = {};
        elseif isstring(value) || ischar(value)
            value = cellstr(value);
        elseif ~iscell(value)
            value = num2cell(value);
        end
        if size(default, 1) <= 1
            value = reshape(value, 1, []);
        else
            value = reshape(value, [], 1);
        end
    elseif islogical(default) && (islogical(value) || isnumeric(value))
        value = logical(value);
    elseif isnumeric(default) && (isnumeric(value) || islogical(value))
        value = cast(value, class(default));
        if isvector(value) && ~isscalar(value)
            if size(default, 1) == 1 || isempty(default)
                value = reshape(value, 1, []);
            elseif size(default, 2) == 1
                value = reshape(value, [], 1);
            end
        end
    end
end
