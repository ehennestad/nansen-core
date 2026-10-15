classdef FileAdapterShim < nansen.FileAdapter
%FileAdapterShim A file adapter that reads and writes through NANSEN dev's file adapter, unchanged
%
%   adapter = nansen.legacy.FileAdapterShim(document) is what the adapter
%   registry gives for a nansen.fileAdapter document with legacyFileAdapter
%   (an adapter imported from dev: adapters.import, or the legacy
%   importer). It puts matlab/devcompat on the path, which holds the base
%   class dev's adapters subclass (nansen.dataio.FileAdapter), and calls
%   dev's code as dev's data I/O model did:
%
%   - a class (kind class): read is obj = Class(path); data = obj.load(),
%     write is obj = Class(path, '-w'); obj.save(data), so its readData
%     and writeData run as they did in dev;
%   - a function-based adapter (kind function, dev's DynamicFileAdapter):
%     read is data = read(path), write is write(path, data), the functions
%     the document names.

    properties (SetAccess = immutable)
        Document struct
    end

    methods
        function obj = FileAdapterShim(document)
            arguments
                document (1,1) struct
            end
            obj.Document = document;
        end

        function data = read(obj, path)
            nansen.legacy.addCompatibility();
            path = char(path);
            legacy = obj.Document.legacyFileAdapter;
            if string(legacy.kind) == "function"
                data = feval(char(legacy.read), path);
            else
                adapter = feval(char(obj.Document.implementations.matlab), path);
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
                adapter.save(data);
            end
        end
    end
end
