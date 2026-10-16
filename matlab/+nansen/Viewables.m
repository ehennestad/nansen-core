classdef Viewables < handle
%Viewables Data viewed without a project: what nansen.view is given
%
%   As dev's imviewer(array), imviewer(file), signalviewer and roimanager
%   opened from the command line. A viewable is an image stack (a file any
%   stack adapter reads, or an array, height x width (x channels (x
%   planes)) x frames) with its ROIs, or frames x N signals. nansen.Api
%   serves frames (view.frame), ROI signals (view.signal) and traces
%   (view.traces) of viewables only, each named by its id (v1, v2, ...):
%   viewables are registered from MATLAB, never by a request, so the page
%   reads no file the user did not hand over. ROIs drawn and edited on a
%   stack (view.updateRois) are saved to its ROI file: the .json ROI file
%   it was given, else <stem>_rois.json beside its file (dev's roimanager
%   saves <stem>_rois.mat there), which is read again when the same file
%   is viewed with no ROIs given; an array's are kept in memory. A method
%   of the built-in modules runs on a stack (view.run, as dev's imviewer
%   runs Align Images and roimanager its autosegmentation): what it saves
%   is written beside the stack's file as <stem>_<variable>.npy or .json,
%   and the stacks and ROIs among it are registered as viewables too.
%   Python's nansen.viewables.Viewables does the same.
%
%   viewables = nansen.Viewables();
%   id = viewables.addStack(data, Name=, Rois=, Adapter=, FrameRate=)
%   id = viewables.addSignals(data, Name=, Variable=, FrameRate=)

    properties (Constant)
        RoiFileEnd = "_rois.json"   % a stack file's ROIs, when it was given none: <stem>_rois.json beside it
    end

    properties (Access = private)
        Ids (1,:) string = string.empty(1, 0)
        % id -> struct: id, kind, name, path, frameRate, adapter, adapters, rois, hasRois, roiFile (where ROI edits are
        % saved; "" in memory), origin ("<viewable id>/<variable>" for what view.run saved), signals
        Items
        Stacks       % "<id>/<adapter>" -> the nansen.Stack it read
        Registry = []
        AllMethods = []   % the built-in modules' methods, once read
    end

    methods
        function obj = Viewables(options)
            arguments
                options.Adapters = []   % a nansen.AdapterRegistry; default: the built-in adapters and the built-in modules'
            end
            obj.Items = containers.Map("KeyType", "char", "ValueType", "any");
            obj.Stacks = containers.Map("KeyType", "char", "ValueType", "any");
            obj.Registry = options.Adapters;
        end

        function registry = adapters(obj)
            %adapters The built-in file adapters and those of the modules that ship with NANSEN (ophys reads TIFF,
            %SciScan raw, HDF5, video, ...): what a file is read with when no project is open
            if isempty(obj.Registry)
                registry = nansen.AdapterRegistry();
                modules = nansen.Module.available("");
                for i = numel(modules):-1:1
                    for document = modules{i}.fileAdapterDocuments()
                        registry.declare(document{1}, modules{i}.MatlabRoot);
                    end
                end
                obj.Registry = registry;
            end
            registry = obj.Registry;
        end

        function n = count(obj)
            n = numel(obj.Ids);
        end

        function result = list(obj)
            %list The viewables: a cell row of structs id, kind (stack or signals), name, path ("" for an array), rois,
            %roiFile (where ROI edits are saved; "" for an array's, kept in memory, and for signals)
            result = cell(1, numel(obj.Ids));
            for i = 1:numel(obj.Ids)
                item = obj.Items(char(obj.Ids(i)));
                result{i} = struct("id", char(item.id), "kind", char(item.kind), "name", char(item.name), ...
                    "path", char(item.path), "rois", item.hasRois, "roiFile", char(item.roiFile));
            end
        end

        function item = get(obj, id)
            %get A viewable by its id; unknown-viewable for any other
            if ~((ischar(id) || (isstring(id) && isscalar(id))) && isKey(obj.Items, char(id)))
                if isnumeric(id) || islogical(id)
                    id = mat2str(id);
                end
                nansen.internal.throwError("unknown-viewable", "nothing to view is registered as '%s'", strjoin(string(id), " "))
            end
            item = obj.Items(char(id));
        end

        function id = addStack(obj, data, options)
            %addStack Register an image stack: a file (read with the adapter given, or the first stack adapter of its
            %extension that opens it) or an array. Rois is an ROI file (.json as ophys saves ROIs, or a file an RoiArray
            %adapter reads, such as dev's roimanager .mat) or an ROI struct. ROI edits are saved to a .json ROI file
            %given, to the same name as .json beside any other ROI file, and else to <stem>_rois.json beside the stack's
            %file, which is read when it is there and no ROIs are given; an array's are kept in memory. Returns the id.
            arguments
                obj
                data
                options.Name (1,1) string = ""
                options.Rois = []
                options.Adapter (1,1) string = ""
                options.FrameRate = []
            end
            item = obj.newItem("stack", options.Name, options.FrameRate);
            if nansen.Viewables.isPath(data)
                item.path = nansen.Viewables.filePath(data);
                [~, name, extension] = fileparts(item.path);
                if item.name == ""
                    item.name = name + extension;
                end
                item.adapters = obj.adapters().forStacks(extension);
                [stack, item.adapter] = obj.openFile(item.path, options.Adapter, item.adapters);
            else
                if item.name == ""
                    item.name = "array";
                end
                stack = nansen.Viewables.arrayStack(data);
            end
            if ~isempty(options.Rois)
                item.rois = obj.readRois(options.Rois);
                item.hasRois = true;
                if nansen.Viewables.isPath(options.Rois)
                    given = nansen.Viewables.filePath(options.Rois);
                    [folder, name, extension] = fileparts(given);
                    item.roiFile = given;
                    if lower(extension) ~= ".json"
                        item.roiFile = string(fullfile(folder, name + ".json"));
                    end
                elseif item.path ~= ""
                    item.roiFile = nansen.Viewables.roiFileBeside(item.path);
                end
            elseif item.path ~= ""
                item.roiFile = nansen.Viewables.roiFileBeside(item.path);
                if isfile(item.roiFile)   % saved when the file was viewed before (view.updateRois)
                    item.rois = obj.readRois(item.roiFile);
                    item.hasRois = true;
                end
            end
            obj.Stacks(char(item.id + "/" + item.adapter)) = stack;
            obj.store(item);
            id = item.id;
        end

        function id = addSignals(obj, data, options)
            %addSignals Register signals, frames x N (a vector is one): an array, a .npy file, or a variable of a .mat
            %file (the one named, or its only numeric array). Returns the id.
            arguments
                obj
                data
                options.Name (1,1) string = ""
                options.Variable (1,1) string = ""
                options.FrameRate = []
            end
            item = obj.newItem("signals", options.Name, options.FrameRate);
            if nansen.Viewables.isPath(data)
                item.path = nansen.Viewables.filePath(data);
                [~, name, extension] = fileparts(item.path);
                switch lower(extension)
                    case ".npy"
                        adapter = obj.adapters().get("npy");
                        value = adapter.read(item.path);
                    case ".mat"
                        adapter = obj.adapters().get("mat");
                        value = nansen.Viewables.pickVariable(adapter.read(item.path), options.Variable, name + extension);
                    otherwise
                        if extension == ""
                            extension = "these";
                        end
                        nansen.internal.throwError("unsupported-file", "signals are read from .npy and .mat files, not %s files", extension)
                end
                if item.name == ""
                    item.name = name;
                    if options.Variable ~= ""
                        item.name = name + "." + options.Variable;
                    end
                end
            else
                value = data;
                if item.name == ""
                    item.name = "signals";
                end
            end
            if ~(isnumeric(value) || islogical(value)) || ~isreal(value) || ~ismatrix(value) || isempty(value)
                nansen.internal.throwError("invalid-data", "%s is not a frames x signals array", item.name)
            end
            item.signals = value;
            obj.store(item);
            id = item.id;
        end

        function ids = register(obj, data, options)
            %register Add stacks (data: one, or a cell array of them) and signals (one, or a cell array); Rois go with
            %the first stack, Name with the only thing given. Returns the ids. nansen.view registers with this.
            arguments
                obj
                data = []
                options.Rois = []
                options.Signals = []
                options.Name (1,1) string = ""
                options.Adapter (1,1) string = ""
                options.Variable (1,1) string = ""
                options.FrameRate = []
            end
            stacks = nansen.Viewables.items(data);
            traces = nansen.Viewables.items(options.Signals);
            if isempty(stacks) && isempty(traces)
                nansen.internal.throwError("invalid-params", "give an image stack or signals to view")
            end
            if ~isempty(options.Rois) && isempty(stacks)
                nansen.internal.throwError("invalid-params", "ROIs are shown over an image stack: give one")
            end
            name = "";
            if numel(stacks) + numel(traces) == 1
                name = options.Name;
            end
            ids = strings(1, 0);
            for i = 1:numel(stacks)
                rois = [];
                if i == 1
                    rois = options.Rois;
                end
                ids(end + 1) = obj.addStack(stacks{i}, Name=name, Rois=rois, Adapter=options.Adapter, ...
                    FrameRate=options.FrameRate); %#ok<AGROW>
            end
            for i = 1:numel(traces)
                ids(end + 1) = obj.addSignals(traces{i}, Name=name, Variable=options.Variable, FrameRate=options.FrameRate); %#ok<AGROW>
            end
        end

        function [stack, adapterId] = stack(obj, item, adapterId)
            %stack The viewable's stack, read with the adapter asked for: one of those that read its extension as stacks
            arguments
                obj
                item (1,1) struct
                adapterId (1,1) string = ""
            end
            if item.kind ~= "stack"
                nansen.internal.throwError("invalid-params", "%s is signals, not an image stack", item.name)
            end
            if adapterId == "" || adapterId == item.adapter
                adapterId = item.adapter;
            elseif item.path == "" || ~ismember(adapterId, item.adapters)
                listed = strjoin(item.adapters, ", ");
                if listed == ""
                    listed = "none";
                end
                nansen.internal.throwError("invalid-params", "%s is read with one of: %s", item.name, listed)
            end
            key = char(item.id + "/" + adapterId);
            if ~isKey(obj.Stacks, key)
                obj.Stacks(key) = obj.openFile(item.path, adapterId, item.adapters);
            end
            stack = obj.Stacks(key);
        end

        function file = saveRois(obj, id, document)
            %saveRois The stack's ROIs from now on, written to its ROI file (as ophys saves ROIs); returns the file, ""
            %for an array's, kept in memory
            item = obj.get(id);
            item.rois = document;
            item.hasRois = true;
            obj.Items(char(item.id)) = item;
            file = item.roiFile;
            if file ~= ""
                nansen.adapters.Json().write(file, document);
            end
        end

        function found = runnableMethods(obj)
            %runnableMethods The methods view.run runs on a stack: those of the built-in modules that run on any entity
            %type, read the stack their stack option names, and have a MATLAB implementation
            found = obj.allMethods();
            keep = arrayfun(@(m) nansen.Viewables.runsOnStacks(m) && any(m.Languages == "matlab"), found);
            found = found(keep);
        end

        function method = findMethod(obj, methodId)
            %findMethod A built-in method by its id; unknown-method for any other
            for candidate = obj.allMethods()
                if candidate.Id == string(methodId)
                    method = candidate;
                    return
                end
            end
            nansen.internal.throwError("unknown-method", "no built-in method '%s'", strjoin(string(methodId), " "))
        end

        function values = presetValues(~, method, name)
            %presetValues A preset of a built-in method: its defaults ("default"), or one its module ships
            if string(name) == "default"
                values = method.defaultOptions();
                return
            end
            modules = nansen.Module.available("");
            for i = 1:numel(modules)
                for document = modules{i}.presetDocuments()
                    if string(document{1}.method.id) == method.Id && string(document{1}.name) == string(name)
                        values = document{1}.values;
                        return
                    end
                end
            end
            nansen.internal.throwError("unknown-preset", "method '%s' has no preset '%s'", method.Id, name)
        end

        function result = runOn(obj, id, methodId, options, preset)
            %runOn Run a built-in method on a stack, now: struct result, log, outputs (variable, path, kind, viewable)
            %
            %   The variable its stack option names is the viewable's stack,
            %   and the one its rois option names (extractSignals', ...) its
            %   ROIs; what it saves is written beside the stack's file as
            %   <stem>_<variable>.npy or .json (kept in memory for an array),
            %   and registered: a stack (3 or more dimensions) as a stack, ROIs
            %   as the viewable's stack with those ROIs, saved to that file.
            %   What one run saved replaces what the run before it saved to the
            %   same variable, under the same id. A run that stops starts over.
            arguments
                obj
                id
                methodId
                options = struct()
                preset (1,1) string = ""
            end
            item = obj.get(id);
            if item.kind ~= "stack"
                nansen.internal.throwError("invalid-params", "%s is signals; methods run on image stacks", item.name)
            end
            method = obj.findMethod(methodId);
            if method.EntityType ~= "*"
                nansen.internal.throwError("wrong-entity-type", "%s runs on %s, not on a stack viewed without a project", ...
                    method.Id, method.EntityType)
            end
            if ~nansen.Viewables.runsOnStacks(method)
                nansen.internal.throwError("invalid-params", "%s reads no stack (it has no stack option), so it cannot run on %s", ...
                    method.Id, item.name)
            end
            if isempty(options)
                options = struct();
            end
            if ~(isstruct(options) && isscalar(options))
                nansen.internal.throwError("invalid-params", "options is an object of option values")
            end
            values = struct();
            if preset ~= ""
                values = obj.presetValues(method, preset);
            end
            values = nansen.internal.mergeStructs(values, options);
            resolved = method.resolveOptions(values);
            roisName = "";
            schema = method.optionsSchema();
            if isfield(schema.properties, "rois")
                roisName = string(resolved.rois);
            end
            sandbox = nansen.internal.ViewableProject(obj, item, string(resolved.stack), roisName);
            context = nansen.MethodContext(Project=sandbox, Method=method);
            results = nansen.runMethod(method, {nansen.Entity("viewable", struct("viewable", char(item.id)))}, values, context);
            value = results{1};
            if isempty(value) && isnumeric(value)
                value = NaN;   % null
            end
            outputs = cell(1, numel(sandbox.Names));
            for i = 1:numel(sandbox.Names)
                outputs{i} = obj.addOutput(item, sandbox.Names(i), sandbox.Paths(i), sandbox.Values{i}, sandbox.InFile(i));
            end
            result = struct("result", {value}, "log", {cellstr(context.Lines)}, "outputs", {outputs});
        end
    end

    methods (Static)
        function metadata = metadata(item, stack)
            %metadata What the stack's files tell, with the frame rate given when they do not tell one
            metadata = stack.Metadata;
            if ~isempty(item.frameRate) && ~isfield(metadata, "frameRate")
                metadata.frameRate = item.frameRate;
            end
        end

        function path = roiFileBeside(path)
            %roiFileBeside Where the ROIs of a stack file are saved when it was given no ROI file: <stem>_rois.json beside it
            [folder, name] = fileparts(string(path));
            path = string(fullfile(folder, name + nansen.Viewables.RoiFileEnd));
        end
    end

    methods
        function rate = rate(obj, item)
            %rate Frames per second: the one given, else what the stack's files tell; [] when neither
            rate = item.frameRate;
            if ~isempty(rate) || item.kind ~= "stack"
                return
            end
            stack = obj.Stacks(char(item.id + "/" + item.adapter));
            given = nansen.internal.getField(stack.Metadata, "frameRate", []);
            if isnumeric(given) && isscalar(given) && isfinite(given) && given > 0
                rate = double(given);
            end
        end
    end

    methods (Access = private)
        function item = newItem(obj, kind, name, frameRate)
            if ~isempty(frameRate) && ~(isnumeric(frameRate) && isscalar(frameRate) && isreal(frameRate) && isfinite(frameRate) && frameRate > 0)
                nansen.internal.throwError("invalid-params", "frame rate is a positive number of frames per second")
            end
            if ~isempty(frameRate)
                frameRate = double(frameRate);
            end
            item = struct("id", "v" + string(numel(obj.Ids) + 1), "kind", string(kind), "name", string(name), "path", "", ...
                "frameRate", frameRate, "adapter", "", "adapters", strings(1, 0), "rois", [], "hasRois", false, ...
                "roiFile", "", "origin", "", "signals", []);
        end

        function store(obj, item)
            obj.Items(char(item.id)) = item;
            if ~ismember(item.id, obj.Ids)
                obj.Ids(end + 1) = item.id;
            end
        end

        function found = allMethods(obj)
            % The built-in modules' methods, the first declaration of an id winning
            if isempty(obj.AllMethods)
                found = nansen.Method.empty(1, 0);
                modules = nansen.Module.available("");
                for i = 1:numel(modules)
                    found = [found, modules{i}.entityMethods()]; %#ok<AGROW>
                end
                if ~isempty(found)
                    [~, first] = unique([found.Id], "stable");
                    found = found(sort(first));
                end
                obj.AllMethods = found;
            end
            found = obj.AllMethods;
        end

        function entry = addOutput(obj, source, variable, path, value, inFile)
            % Register what a run saved, when it is a stack or ROIs: the entry of view.run's outputs. inFile: the value
            % is in the file at path (an array a stack writer wrote, or one saved as .npy), not at hand
            stack = [];
            hasStack = false;
            kind = "data";
            if inFile && endsWith(path, ".npy")
                stack = nansen.adapters.Npy().open(path);
                hasStack = true;
            elseif ~inFile && nansen.Viewables.isArray(value)
                stack = nansen.Stack.fromArray(value);
                hasStack = true;
            end
            if hasStack && ndims(stack) >= 3
                kind = "stack";
            elseif ~inFile && isstruct(value) && isscalar(value) && isfield(value, "rois")
                try
                    nansen.internal.roiOutlines(value);
                    kind = "rois";
                catch err
                    if ~isa(err, "nansen.NansenError")
                        rethrow(err)
                    end
                end
            end
            entry = struct("variable", char(variable), "path", char(path), "kind", char(kind), "viewable", '');
            if kind == "data"
                return
            end
            origin = source.id + "/" + variable;
            item = obj.newItem("stack", source.name + " · " + variable, source.frameRate);
            for i = 1:numel(obj.Ids)
                other = obj.Items(char(obj.Ids(i)));
                if other.origin == origin   % what the run before saved to the variable: replaced, under its id
                    item.id = other.id;
                    for key = string(keys(obj.Stacks))
                        if startsWith(key, item.id + "/")
                            remove(obj.Stacks, char(key));
                        end
                    end
                    break
                end
            end
            item.origin = origin;
            sourceStack = obj.Stacks(char(source.id + "/" + source.adapter));
            if kind == "stack"
                stack = nansen.Viewables.imageStack(stack, item.name);
                if isempty(fieldnames(stack.Metadata))   % an aligned stack keeps what the recording's files tell
                    stack.Metadata = sourceStack.Metadata;
                end
                item.path = string(path);
                if item.path ~= ""
                    item.adapter = "npy";
                    item.adapters = obj.adapters().forStacks(".npy");
                    item.roiFile = nansen.Viewables.roiFileBeside(item.path);
                    if isfile(item.roiFile)
                        item.rois = obj.readRois(item.roiFile);
                        item.hasRois = true;
                    end
                end
                obj.Stacks(char(item.id + "/" + item.adapter)) = stack;
            else   % ROIs found in the stack: shown over it, edits saved to their file
                item.path = source.path;
                item.adapter = source.adapter;
                item.adapters = source.adapters;
                item.rois = value;
                item.hasRois = true;
                item.roiFile = string(path);
                obj.Stacks(char(item.id + "/" + item.adapter)) = sourceStack;
            end
            obj.store(item);
            entry.viewable = char(item.id);
        end

        function [stack, adapterId] = openFile(obj, path, adapterId, candidates)
            tries = candidates;
            if adapterId ~= ""
                tries = adapterId;
            end
            [~, name, extension] = fileparts(path);
            if isempty(tries)
                if extension == ""
                    extension = "these";
                end
                nansen.internal.throwError("unsupported-file", "no file adapter reads %s files as image stacks", extension)
            end
            problems = strings(1, 0);
            for candidate = tries
                adapter = obj.adapters().get(candidate);
                try
                    if ismethod(adapter, "open")
                        stack = adapter.open(path);
                    else
                        stack = adapter.read(path);
                    end
                    stack = nansen.Viewables.imageStack(stack, name + extension);
                    stack = nansen.internal.withDevMetadata(stack, path);   % and dev's metadata file beside it
                catch err
                    if adapterId ~= "" || ~startsWith(string(err.identifier), "nansen:")
                        rethrow(err)
                    end
                    problems(end + 1) = candidate + ": " + string(err.message); %#ok<AGROW>
                    continue
                end
                adapterId = candidate;
                return
            end
            nansen.internal.throwError("invalid-data", "%s could not be read as a stack: %s", name + extension, strjoin(problems, "; "))
        end

        function value = readRois(obj, rois)
            if ~nansen.Viewables.isPath(rois)
                nansen.internal.roiOutlines(rois);   % an ROI struct: rois, each with pixels
                value = rois;
                return
            end
            path = nansen.Viewables.filePath(rois);
            [~, name, extension] = fileparts(path);
            candidates = obj.adapters().forRois(extension);
            if isempty(candidates)
                if extension == ""
                    extension = "these";
                end
                nansen.internal.throwError("unsupported-file", "no file adapter reads %s files as ROIs", extension)
            end
            problems = strings(1, 0);
            for candidate = candidates
                try
                    adapter = obj.adapters().get(candidate);
                    value = adapter.read(path);
                    nansen.internal.roiOutlines(value);
                catch err
                    if ~startsWith(string(err.identifier), "nansen:")
                        rethrow(err)
                    end
                    problems(end + 1) = candidate + ": " + string(err.message); %#ok<AGROW>
                    continue
                end
                return
            end
            nansen.internal.throwError("invalid-data", "%s could not be read as ROIs: %s", name + extension, strjoin(problems, "; "))
        end
    end

    methods (Static, Access = private)
        function list = items(value)
            % One thing to view, or a cell array of them (a string array of several paths too); [] for none
            if iscell(value)
                list = reshape(value, 1, []);
            elseif isstring(value) && ~isscalar(value)
                list = cellstr(reshape(value, 1, []));
            elseif isempty(value) && ~isa(value, "nansen.Stack")
                list = {};
            else
                list = {value};
            end
        end

        function tf = isPath(value)
            tf = ischar(value) || (isstring(value) && isscalar(value));
        end

        function tf = isArray(value)
            % An array of numbers or truth values, more than one: saved as .npy (as Project.save makes a variable)
            tf = (isnumeric(value) || islogical(value)) && numel(value) > 1;
        end

        function tf = runsOnStacks(method)
            % A method view.run runs: of any entity type, with a stack option naming the stack it reads
            schema = method.optionsSchema();
            tf = method.EntityType == "*" && isfield(schema, "properties") && isstruct(schema.properties) ...
                && isfield(schema.properties, "stack");
        end

        function path = filePath(value)
            %filePath The file's full path; file-not-found if it is not a file
            path = string(value);
            if ~isfile(path)
                nansen.internal.throwError("file-not-found", "%s is not a file", path)
            end
            info = dir(path);
            path = string(fullfile(info(1).folder, info(1).name));
        end

        function stack = imageStack(stack, name)
            if ~isa(stack, "nansen.Stack")
                if ~(isnumeric(stack) || islogical(stack)) || ~isreal(stack) || ndims(stack) > 5 || isvector(stack)
                    nansen.internal.throwError("invalid-data", "%s is not an image or a stack of images", name)
                end
                stack = nansen.Stack.fromArray(stack, max(3, ndims(stack)));
            elseif ndims(stack) > 5 || ~ismember(stack.ClassName, ["logical", "uint8", "int8", "uint16", "int16", ...
                    "uint32", "int32", "uint64", "int64", "single", "double"])
                nansen.internal.throwError("invalid-data", "%s is not an image or a stack of images", name)
            end
        end

        function stack = arrayStack(data)
            if isa(data, "nansen.Stack")
                stack = nansen.Viewables.imageStack(data, "the stack");
                return
            end
            if ~(isnumeric(data) || islogical(data)) || ~isreal(data) || ndims(data) > 5 || isvector(data)
                nansen.internal.throwError("invalid-data", "the array is not an image (height x width) or a stack of images (frames last)")
            end
            stack = nansen.Stack.fromArray(data, max(3, ndims(data)));
        end

        function value = pickVariable(variables, name, filename)
            names = string(fieldnames(variables))';
            if name ~= ""
                if ~ismember(name, names)
                    listed = strjoin(sort(names), ", ");
                    if listed == ""
                        listed = "none";
                    end
                    nansen.internal.throwError("invalid-params", "%s has no variable '%s'; it has %s", filename, name, listed)
                end
                value = variables.(name);
                return
            end
            numeric = strings(1, 0);
            for candidate = names
                v = variables.(candidate);
                if (isnumeric(v) || islogical(v)) && ismatrix(v)
                    numeric(end + 1) = candidate; %#ok<AGROW>
                end
            end
            if numel(numeric) ~= 1
                listed = strjoin(sort(numeric), ", ");
                if listed == ""
                    listed = "none";
                end
                nansen.internal.throwError("invalid-params", "which variable of %s are the signals? Name one of: %s", filename, listed)
            end
            value = variables.(numeric(1));
        end
    end
end
