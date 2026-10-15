classdef AdapterRegistry < handle
%AdapterRegistry File adapter ids to adapters: built-ins plus declared ones
%
%   Built per project and passed around; there is no global registry.
%   Declared MATLAB adapters are classes; the declaring folder is put on the
%   path when the adapter is first used, since MATLAB finds classes there.

    properties (Access = private)
        Adapters
        Declarations
        Folders
    end

    methods
        function obj = AdapterRegistry(options)
            arguments
                options.IncludeBuiltIn (1,1) logical = true
            end
            obj.Adapters = containers.Map("KeyType", "char", "ValueType", "any");
            obj.Declarations = containers.Map("KeyType", "char", "ValueType", "any");
            obj.Folders = containers.Map("KeyType", "char", "ValueType", "char");
            if options.IncludeBuiltIn
                obj.Adapters("json") = nansen.adapters.Json();
                obj.Adapters("text") = nansen.adapters.Text();
                obj.Adapters("mat") = nansen.adapters.Mat();
                obj.Adapters("npy") = nansen.adapters.Npy();
                obj.Adapters("csv") = nansen.adapters.Csv();
                obj.Adapters("excel") = nansen.adapters.Excel();
            end
        end

        function register(obj, adapterId, adapter)
            obj.Adapters(char(adapterId)) = adapter;
        end

        function declare(obj, document, folder)
            %declare Add a nansen.fileAdapter declaration; folder holds its MATLAB class
            arguments
                obj
                document (1,1) struct
                folder (1,1) string = ""
            end
            id = char(document.id);
            obj.Declarations(id) = document;
            obj.Folders(id) = char(folder);
            if isKey(obj.Adapters, id)
                remove(obj.Adapters, id);
            end
        end

        function ids = ids(obj)
            ids = sort(unique(string([keys(obj.Adapters), keys(obj.Declarations), {'npy'}])));
        end

        function tf = has(obj, adapterId)
            tf = ismember(string(adapterId), obj.ids());
        end

        function info = describe(obj, adapterId)
            adapterId = char(adapterId);
            if isKey(obj.Declarations, adapterId)
                doc = obj.Declarations(adapterId);
                info = struct("id", adapterId, "title", char(nansen.internal.getField(doc, "title", adapterId)), ...
                    "extensions", {nansen.internal.asCellstr(nansen.internal.getField(doc, "extensions", {}))}, ...
                    "languages", {sort(fieldnames(doc.implementations))'}, "builtIn", false);
                return
            end
            builtIn = struct("json", {{".json"}}, "text", {{".txt", ".log", ".md"}}, "mat", {{".mat"}}, "npy", {{".npy"}}, ...
                "csv", {{".csv"}}, "excel", {{".xlsx"}});
            if ~isfield(builtIn, adapterId)
                nansen.internal.throwError("unknown-file-adapter", "no file adapter '%s'", adapterId)
            end
            languages = {'matlab', 'python'};
            info = struct("id", adapterId, "title", adapterId, "extensions", {builtIn.(adapterId)}, ...
                "languages", {languages}, "builtIn", true);
        end

        function ids = forExtension(obj, extension)
            %forExtension Ids of the adapters, built-in and declared, that name an extension among theirs, in id order
            extension = lower(string(extension));
            ids = strings(1, 0);
            for id = obj.ids()
                extensions = lower(string(obj.describe(id).extensions));
                if any(extensions == extension)
                    ids(end + 1) = id; %#ok<AGROW>
                end
            end
        end

        function ids = forStacks(obj, extension)
            %forStacks Ids of the adapters that read files of an extension as image stacks, in id order
            %
            %   Those declared with data type ImageStack, and the built-in npy for .npy.
            extension = lower(string(extension));
            ids = strings(1, 0);
            for id = string(keys(obj.Declarations))
                doc = obj.Declarations(char(id));
                extensions = lower(string(nansen.internal.asCellstr(nansen.internal.getField(doc, "extensions", {}))));
                if string(nansen.internal.getField(doc, "dataType", "")) == "ImageStack" && any(extensions == extension)
                    ids(end + 1) = id; %#ok<AGROW>
                end
            end
            if extension == ".npy"
                ids(end + 1) = "npy";
            end
            ids = sort(ids);
        end

        function ids = forRois(obj, extension)
            %forRois Ids of the adapters that read files of an extension as ROIs, in id order
            %
            %   Those declared with data type RoiArray, and the built-in json for .json (the ROI document as ophys saves it).
            extension = lower(string(extension));
            ids = strings(1, 0);
            for id = string(keys(obj.Declarations))
                doc = obj.Declarations(char(id));
                extensions = lower(string(nansen.internal.asCellstr(nansen.internal.getField(doc, "extensions", {}))));
                if string(nansen.internal.getField(doc, "dataType", "")) == "RoiArray" && any(extensions == extension)
                    ids(end + 1) = id; %#ok<AGROW>
                end
            end
            if extension == ".json"
                ids(end + 1) = "json";
            end
            ids = sort(ids);
        end

        function adapter = get(obj, adapterId)
            adapterId = char(adapterId);
            if isKey(obj.Adapters, adapterId)
                adapter = obj.Adapters(adapterId);
                return
            end
            if ~isKey(obj.Declarations, adapterId)
                nansen.internal.throwError("unknown-file-adapter", "no file adapter '%s'", adapterId)
            end
            implementations = obj.Declarations(adapterId).implementations;
            if ~isfield(implementations, "matlab")
                nansen.internal.throwError("adapter-unavailable", "file adapter '%s' has no MATLAB implementation", adapterId)
            end
            folder = obj.Folders(adapterId);
            if ~isempty(folder) && ~contains(path, folder)
                addpath(folder);
            end
            if isfield(obj.Declarations(adapterId), "legacyFileAdapter")   % dev's own code, run through dev's base class
                adapter = nansen.legacy.FileAdapterShim(obj.Declarations(adapterId));
                obj.Adapters(adapterId) = adapter;
                return
            end
            className = char(implementations.matlab);
            if ~exist(className, "class")
                nansen.internal.throwError("adapter-unavailable", "class %s is not on the path", className)
            end
            adapter = feval(className);
            obj.Adapters(adapterId) = adapter;
        end
    end
end
