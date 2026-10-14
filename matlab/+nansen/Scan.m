classdef Scan
%Scan What one walk of the stores found: DSM entity records and the roots read
%
%   Records and Unmatched are row cell arrays of structs in the JSON form of
%   DSM's EntityRecord; Roots is a row cell array of structs with
%   dataLocation, rootStoragePath, path, available and entries.

    properties
        Records (1,:) cell = {}
        Unmatched (1,:) cell = {}
        Roots (1,:) cell = {}
        Environment (1,1) string = ""
        ScannedAt (1,1) string = ""
    end

    methods
        function obj = Scan(records, unmatched, roots, environment, scannedAt)
            arguments
                records (1,:) cell = {}
                unmatched (1,:) cell = {}
                roots (1,:) cell = {}
                environment (1,1) string = ""
                scannedAt (1,1) string = ""
            end
            obj.Records = records;
            obj.Unmatched = unmatched;
            obj.Roots = roots;
            obj.Environment = environment;
            obj.ScannedAt = scannedAt;
        end

        function records = recordsOf(obj, entityType)
            keep = cellfun(@(r) string(r.entityType) == entityType, obj.Records);
            records = obj.Records(keep);
        end

        function doc = toDocument(obj)
            entry = nansen.internal.schemaEntry("nansen.scan");
            environment = NaN;   % encodes as null
            if obj.Environment ~= ""
                environment = char(obj.Environment);
            end
            doc = struct("schemaType", 'nansen.scan', "schemaVersion", char(entry.version), ...
                "scannedAt", char(obj.ScannedAt), "environment", environment, ...
                "roots", {obj.Roots}, "records", {obj.Records}, "unmatched", {obj.Unmatched});
        end

        function write(obj, path)
            arguments
                obj
                path (1,1) string
            end
            folder = fileparts(path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            doc = nansen.checkDocument(obj.toDocument(), ExpectedType="nansen.scan");
            nansen.internal.writeJson(path, doc)
        end
    end

    methods (Static)
        function obj = fromDocument(doc)
            environment = nansen.internal.getField(doc, "environment", []);
            if isempty(environment)
                environment = "";
            end
            obj = nansen.Scan(nansen.internal.asCellOfStructs(doc.records), ...
                nansen.internal.asCellOfStructs(doc.unmatched), nansen.internal.asCellOfStructs(doc.roots), ...
                string(environment), string(doc.scannedAt));
        end

        function obj = read(path)
            obj = nansen.Scan.fromDocument(nansen.readDocument(path, ExpectedType="nansen.scan"));
        end
    end
end
