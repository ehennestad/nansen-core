function info = analyzeFileAdapter(name, text, options)
%analyzeFileAdapter What a NANSEN dev file adapter says about itself, read from its text without running it
%
%   info = nansen.legacy.analyzeFileAdapter(name, text) for the class file
%   name.m gives title (the class's name), description, extensions and
%   dataType. A class is a dev file adapter when it subclasses
%   nansen.dataio.FileAdapter, or one of dev's own adapters (its ImageStack,
%   RoiGroup, RoiSignalArray, ...), and no other class of dev's nansen; its
%   constant DataType, SUPPORTED_FILE_TYPES ('tif' or {'tif', 'tiff'}) and
%   Description say the rest, or else the first line of its help text. A
%   class on one of dev's adapters has that adapter's data type and file
%   types, and also base (that adapter's class), builtIn (per row an
%   extension and the adapter here that reads and writes such a file in
%   place of dev's adapter) and overrides (whether it has a readData or
%   writeData of its own).
%
%   info = analyzeFileAdapter(namespace, text, Files=names) reads the
%   fileadapter.json of dev's function-based adapter (DynamicFileAdapter)
%   in the package folder of that name, whose files are names: title (its
%   Name), description, extensions (SupportedFileTypes), dataType, and read
%   and write, its functions (ReadFunction and WriteFunction, or read.m and
%   write.m in the folder; write is "" when it only reads).
%
%   unsupported-file when it is not a dev file adapter. The rules are those
%   of Python's nansen.legacyadapters.analyze_class and analyze_function.
    arguments
        name (1,1) string
        text
        options.Files string = missing
    end
    text = string(text);
    if ~(isscalar(options.Files) && ismissing(options.Files))
        info = functionAdapter(name, text, reshape(options.Files, 1, []));
        return
    end
    text = replace(replace(text, sprintf("\r\n"), newline), sprintf("\r"), newline);
    lines = reshape(split(text, newline), 1, []);
    first = 0;
    for i = 1:numel(lines)
        stripped = strtrim(lines(i));
        if stripped ~= "" && ~startsWith(stripped, "%")
            first = i;
            break
        end
    end
    if first == 0
        nansen.internal.throwError("unsupported-file", "%s.m holds no code", name)
    end
    declaration = char(strtrim(codeOf(lines(first))));
    if isempty(regexp(declaration, '^classdef(?!\w)', 'once'))
        nansen.internal.throwError("unsupported-file", "%s.m is not a class, so it is not a dev file adapter", name)
    end
    fileAdapter = "nansen.dataio.FileAdapter";
    % the superclasses: after the < of the declaration (outside its attributes in brackets), split at &
    attributes = regexp(declaration, '^classdef\s*\([^)]*\)', 'end', 'once');
    if isempty(attributes)
        attributes = 0;
    end
    at = find(declaration == '<' & (1:numel(declaration)) > attributes, 1);
    supers = strings(1, 0);
    if ~isempty(at)
        supers = reshape(strtrim(split(string(declaration(at + 1:end)), "&")), 1, []);
    end
    bases = supers(arrayfun(@(s) ~isempty(devAdapterBase(s)), supers));
    isAdapter = ismember(fileAdapter, supers) || ~isempty(bases);
    others = supers(startsWith(supers, "nansen.") & supers ~= fileAdapter & ~ismember(supers, bases));
    if ~isempty(others)
        also = "";
        if isAdapter
            also = "also ";
        end
        nansen.internal.throwError("unsupported-file", "%s.m %ssubclasses %s, which nansen-core does not have", ...
            name, also, strjoin(others, ", "))
    end
    if ~isAdapter
        nansen.internal.throwError("unsupported-file", "%s.m is a class that does not subclass %s " + ...
            "or one of dev's file adapters, so it is not a dev file adapter", name, fileAdapter)
    end
    if numel(bases) > 1
        nansen.internal.throwError("unsupported-file", "%s.m subclasses several of dev's file adapters (%s)", ...
            name, strjoin(bases, ", "))
    end
    info = struct("title", name, "description", describe(lines, first, name), "extensions", strings(1, 0), ...
        "dataType", "");
    overrides = false;
    for i = 1:numel(lines)
        code = codeOf(lines(i));
        if ~isempty(regexp(code, '^\s*function\s+(?:[^=(]*=\s*)?(?:readData|writeData)\s*(?:\(|$)', 'once'))
            overrides = true;
        end
        value = quotedValue(code, 'DataType');
        if ~ismissing(value) && info.dataType == ""
            info.dataType = strtrim(value);
        end
        value = quotedValue(code, 'Description');
        if ~ismissing(value) && strtrim(value) ~= ""
            info.description = strtrim(value);
        end
        types = regexp(code, '^\s*SUPPORTED_FILE_TYPES\s*=\s*(.*)$', 'tokens', 'once');
        if ~isempty(types) && isempty(info.extensions)
            info.extensions = extensionsOf(textsOf(types{1}));
        end
    end
    if ~isempty(bases)   % dev's class's constants, which a subclass cannot set again
        base = devAdapterBase(bases(1));
        info.dataType = base.dataType;
        info.extensions = base.extensions;
        info.base = bases(1);
        info.builtIn = base.builtIn;
        info.overrides = overrides;
    end
end

function base = devAdapterBase(name)
    % dev's own file adapter classes that a project's adapter may subclass, as readers of known formats: the data type
    % and file types of dev's class (its constants, which a subclass keeps), and the adapter here that reads and writes
    % a file of each type in its place (builtIn: extension, adapter id per row); [] for any other class. The core and
    % two-photon modules' classes of the same names only subclass these. As Python's legacyadapters.DEV_ADAPTER_BASES.
    switch char(name)
        case {'nansen.dataio.fileadapter.imagestack.ImageStack', 'nansen.module.general.core.fileadapter.ImageStack'}
            base = struct("dataType", "ImageStack", "extensions", [".ini", ".raw", ".tif", ".tiff", ".avi", ".h5", ".tsm"], ...
                "builtIn", [".raw", "ophys.binary_stack"; ".tif", "ophys.tiff_stack"; ".tiff", "ophys.tiff_stack"; ...
                ".avi", "ophys.video_file"; ".h5", "ophys.hdf5_stack"; ".tsm", "ophys.tsm_stack"]);
        case {'nansen.dataio.fileadapter.roi.RoiGroup', 'nansen.module.ophys.twophoton.fileadapter.RoiGroup'}
            base = struct("dataType", "RoiArray", "extensions", [".mat", ".npy"], ...
                "builtIn", [".mat", "ophys.nansen_roi_array"; ".npy", "ophys.suite2p_rois"]);
        case {'nansen.dataio.fileadapter.roi.RoiArray', 'nansen.internal.dataio.fileadapter.RoiArray'}
            base = struct("dataType", "RoiArray", "extensions", ".mat", "builtIn", [".mat", "ophys.nansen_roi_array"]);
        case {'nansen.dataio.fileadapter.timeseries.RoiSignalArray', 'nansen.module.ophys.twophoton.fileadapter.RoiSignalArray'}
            base = struct("dataType", "RoiSignalArray", "extensions", ".mat", "builtIn", [".mat", "mat"]);
        case 'nansen.dataio.fileadapter.timeseries.TimeSeries'
            base = struct("dataType", "timeseries", "extensions", ".mat", "builtIn", [".mat", "mat"]);
        case 'nansen.dataio.fileadapter.internal.RoiGroupStruct'
            base = struct("dataType", "struct", "extensions", ".mat", "builtIn", [".mat", "mat"]);
        case {'nansen.dataio.fileadapter.numpy', 'nansen.module.general.core.fileadapter.Numpy2Mat'}
            base = struct("dataType", "struct", "extensions", ".npy", "builtIn", [".npy", "npy"]);
        otherwise
            base = [];
    end
end

function info = functionAdapter(namespace, text, files)
    % dev's fileadapter.json: _type FileAdapter, with Properties Name, Description, SupportedFileTypes, DataType,
    % ReadFunction and WriteFunction
    try
        document = jsondecode(char(text));
    catch
        nansen.internal.throwError("unsupported-file", "%s: its fileadapter.json is not valid JSON", namespace)
    end
    if ~(isstruct(document) && isscalar(document) && isfield(document, "x_type") && isequal(document.x_type, 'FileAdapter') ...
            && isfield(document, "Properties") && isstruct(document.Properties) && isscalar(document.Properties))
        nansen.internal.throwError("unsupported-file", "%s: its fileadapter.json is not a dev file adapter (_type FileAdapter)", namespace)
    end
    fields = document.Properties;
    title = textOf(fields, "Name");
    if title == ""
        parts = split(namespace, ".");
        title = parts(end);
    end
    types = {};
    if isfield(fields, "SupportedFileTypes")
        types = fields.SupportedFileTypes;
        if ischar(types) || isstring(types)
            types = cellstr(types);
        elseif ~iscell(types)
            types = {};
        end
    end
    info = struct("title", title, "description", textOf(fields, "Description"), ...
        "extensions", extensionsOf(types), "dataType", textOf(fields, "DataType"), "read", "", "write", "");
    for role = ["read", "write"]
        functionName = textOf(fields, upper(extractBefore(role, 2)) + extractAfter(role, 1) + "Function");
        if functionName == "" && ismember(role + ".m", files)
            functionName = namespace + "." + role;
        end
        if functionName ~= "" && isempty(regexp(char(functionName), '^[A-Za-z][A-Za-z0-9_.]*$', 'once'))
            nansen.internal.throwError("unsupported-file", "%s: its %sFunction %s is not the name of a function", ...
                namespace, upper(extractBefore(role, 2)) + extractAfter(role, 1), functionName)
        end
        info.(role) = functionName;
    end
    if info.read == ""
        nansen.internal.throwError("unsupported-file", "%s: it has no read function (ReadFunction or read.m)", namespace)
    end
end

function value = textOf(s, name)
    value = "";
    if isfield(s, name) && (ischar(s.(name)) || (isstring(s.(name)) && isscalar(s.(name))))
        value = strtrim(string(s.(name)));
    end
end

function value = quotedValue(code, name)
    % The text of a constant such as DataType = 'double' (or "double"), missing when the line does not set it
    value = string(missing);
    tokens = regexp(code, ['^\s*', name, '\s*=\s*''([^'']*)'''], 'tokens', 'once');
    if isempty(tokens)
        tokens = regexp(code, ['^\s*', name, '\s*=\s*"([^"]*)"'], 'tokens', 'once');
    end
    if ~isempty(tokens)
        value = string(tokens{1});
    end
end

function extensions = extensionsOf(items)
    % dev's SUPPORTED_FILE_TYPES as extensions: '.tif', '.tiff' (as written, once each)
    extensions = strings(1, 0);
    for i = 1:numel(items)
        item = items{i};
        if ~(ischar(item) || (isstring(item) && isscalar(item)))
            continue
        end
        extension = "." + regexprep(strtrim(string(item)), '^\.+', '');
        if ~isempty(regexp(char(extension), '^\.[A-Za-z0-9.]+$', 'once')) && ~ismember(extension, extensions)
            extensions(end + 1) = extension; %#ok<AGROW>
        end
    end
end

function items = textsOf(code)
    % The text of a plain value, 'tif' or {'tif', "tiff"}, as a cell; {} for any other value
    code = strtrim(char(code));
    while ~isempty(code) && (code(end) == ';' || code(end) == ',')
        code = strtrim(code(1:end - 1));
    end
    quoted = ['''(?:[^'']|'''')*''', '|', '"(?:[^"]|"")*"'];
    items = {};
    if ~isempty(regexp(code, ['^(?:', quoted, ')$'], 'once'))
        items = {unquote(code)};
    elseif numel(code) >= 2 && code(1) == '{' && code(end) == '}'
        inner = code(2:end - 1);
        if all(ismember(regexprep(inner, quoted, ''), [' ', ',', sprintf('\t')]))
            items = cellfun(@unquote, regexp(inner, quoted, 'match'), UniformOutput=false);
        end
    end
end

function text = unquote(text)
    quote = text(1);
    text = strrep(text(2:end - 1), [quote, quote], quote);
end

function description = describe(lines, first, name)
    % The first line of the help text (the comments after the declaration), less a leading word that is the name
    description = "";
    if first + 1 > numel(lines) || ~startsWith(strtrim(lines(first + 1)), "%")
        return
    end
    text = strtrim(regexprep(char(strtrim(lines(first + 1))), '^%+\s*', ''));
    tokens = regexp(text, '^(\S+)\s*(.*)$', 'tokens', 'once');
    if ~isempty(tokens) && strcmp(lower(tokens{1}), lower(char(name)))
        text = strtrim(tokens{2});
    end
    description = string(text);
end

function code = codeOf(line)
    % A line's code: the text before a % outside quotes
    line = char(line);
    code = line;
    quote = '';
    for k = 1:numel(line)
        c = line(k);
        if ~isempty(quote)
            if c == quote
                quote = '';
            end
        elseif c == '"' || (c == '''' && (k == 1 || isempty(regexp(line(k - 1), '[\w)\]}.]', 'once'))))
            quote = c;   % a ' after a name, a closing bracket or a dot is a transpose
        elseif c == '%'
            code = line(1:k - 1);
            return
        end
    end
end
