classdef Viewables < handle
%Viewables Data viewed without a project: what nansen.view is given
%
%   As dev's imviewer(array), imviewer(file), signalviewer and roimanager
%   opened from the command line. A viewable is an image stack (a file any
%   stack adapter reads, or an array, height x width (x channels (x
%   planes)) x frames) with ROIs to show over it, read only, or frames x N
%   signals. nansen.Api serves frames (view.frame), ROI signals
%   (view.signal) and traces (view.traces) of viewables only, each named
%   by its id (v1, v2, ...): viewables are registered from MATLAB, never
%   by a request, so the page reads no file the user did not hand over.
%   Python's nansen.viewables.Viewables does the same.
%
%   viewables = nansen.Viewables();
%   id = viewables.addStack(data, Name=, Rois=, Adapter=, FrameRate=)
%   id = viewables.addSignals(data, Name=, Variable=, FrameRate=)

    properties (Access = private)
        Ids (1,:) string = string.empty(1, 0)
        Items        % id -> struct: id, kind, name, path, frameRate, adapter, adapters, rois, hasRois, signals
        Stacks       % "<id>/<adapter>" -> the nansen.Stack it read
        Registry = []
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
            %list The viewables: a cell row of structs id, kind (stack or signals), name, path ("" for an array), rois
            result = cell(1, numel(obj.Ids));
            for i = 1:numel(obj.Ids)
                item = obj.Items(char(obj.Ids(i)));
                result{i} = struct("id", char(item.id), "kind", char(item.kind), "name", char(item.name), ...
                    "path", char(item.path), "rois", item.hasRois);
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
            %adapter reads, such as dev's roimanager .mat) or an ROI struct, shown read only. Returns the id.
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
    end

    methods (Static)
        function metadata = metadata(item, stack)
            %metadata What the stack's files tell, with the frame rate given when they do not tell one
            metadata = stack.Metadata;
            if ~isempty(item.frameRate) && ~isfield(metadata, "frameRate")
                metadata.frameRate = item.frameRate;
            end
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
                "frameRate", frameRate, "adapter", "", "adapters", strings(1, 0), "rois", [], "hasRois", false, "signals", []);
        end

        function store(obj, item)
            obj.Items(char(item.id)) = item;
            obj.Ids(end + 1) = item.id;
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
