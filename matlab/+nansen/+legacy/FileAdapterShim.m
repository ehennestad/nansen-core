classdef FileAdapterShim < nansen.FileAdapter
%FileAdapterShim A file adapter that reads and writes through NANSEN dev's file adapter, unchanged
%
%   adapter = nansen.legacy.FileAdapterShim(document, registry) is what the
%   adapter registry gives for a nansen.fileAdapter document with
%   legacyFileAdapter (an adapter imported from dev: adapters.import, or
%   the legacy importer). It puts matlab/devcompat on the path, which holds
%   the base class dev's adapters subclass (nansen.dataio.FileAdapter), and
%   dev's own adapter classes they may subclass instead, and calls dev's
%   code as dev's data I/O model did:
%
%   - a class (kind class): read is obj = Class(path); data = obj.load(),
%     write is obj = Class(path, '-w'); obj.save(data), so its readData
%     and writeData run as they did in dev. A class on one of dev's own
%     adapters (base: its ImageStack, RoiGroup, RoiSignalArray, ...) is
%     given the adapter of the registry that reads and writes a file of
%     the path's type in place of dev's (builtIn: the ophys module's
%     stacks and ROIs, or a built-in), which devcompat's class of dev's
%     reads and writes with;
%   - a function-based adapter (kind function, dev's DynamicFileAdapter):
%     read is data = read(path), write is write(path, data), the functions
%     the document names.

    properties (SetAccess = immutable)
        Document struct
    end

    properties (Access = private)
        Registry   % the project's nansen.AdapterRegistry, which has the adapters of builtIn
    end

    methods
        function obj = FileAdapterShim(document, registry)
            arguments
                document (1,1) struct
                registry = []
            end
            obj.Document = document;
            obj.Registry = registry;
        end

        function data = read(obj, path)
            nansen.legacy.addCompatibility();
            path = char(path);
            legacy = obj.Document.legacyFileAdapter;
            if string(legacy.kind) == "function"
                data = feval(char(legacy.read), path);
            else
                adapter = feval(char(obj.Document.implementations.matlab), path);
                obj.giveCoreAdapter(adapter, path);
                data = adapter.load();
            end
        end

        function write(obj, path, data)
            nansen.legacy.addCompatibility();
            path = char(path);
            legacy = obj.Document.legacyFileAdapter;
            if string(legacy.kind) == "function"
                if ~isfield(legacy, "write") || strlength(string(legacy.write)) == 0
                    error("nansen:Legacy:ReadOnlyAdapter", "The file adapter %s (dev's %s) only reads files", ...
                        obj.Document.id, obj.Document.implementations.matlab)
                end
                feval(char(legacy.write), path, data);
            else
                adapter = feval(char(obj.Document.implementations.matlab), path, '-w');
                obj.giveCoreAdapter(adapter, path);
                adapter.save(data);
            end
        end
    end

    methods (Access = private)
        function giveCoreAdapter(obj, adapter, path)
            % A class on one of dev's own adapters reads and writes with the registry's adapter of the file's type
            legacy = obj.Document.legacyFileAdapter;
            if ~isfield(legacy, "builtIn") || isempty(obj.Registry)
                return
            end
            [~, ~, extension] = fileparts(path);
            for entry = nansen.internal.asCellOfStructs(legacy.builtIn)
                if strcmpi(entry{1}.extension, extension)
                    try
                        adapter.CoreAdapter = obj.Registry.get(entry{1}.fileAdapter);
                    catch
                        % the project has not got it (nor its module): dev's class says so, when it reads with it
                    end
                    return
                end
            end
        end
    end
end
