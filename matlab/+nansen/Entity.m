classdef Entity
%Entity One entity: its DSM record (what the stores say) joined with its table row (what people authored)
%
%   Key is a struct of key column values. Record is the DSM entity record in
%   JSON form, or [] when the last scan did not find the entity. Row is the
%   table row as a struct, or [] when the table has none.

    properties (SetAccess = private)
        EntityType (1,1) string
        Key (1,1) struct
        Record = []
        Row = []
        % Issue structs (code, message): the record's issues plus incomplete-key
        Issues (1,:) cell = {}
        % The nansen.Project the entity came from, so it can read and write its data
        Project = []
    end

    methods
        function obj = Entity(entityType, key, record, row, issues)
            arguments
                entityType (1,1) string
                key (1,1) struct
                record = []
                row = []
                issues (1,:) cell = {}
            end
            obj.EntityType = entityType;
            obj.Key = key;
            obj.Record = record;
            obj.Row = row;
            if ~isempty(record)
                obj.Issues = nansen.internal.asCellOfStructs(nansen.internal.getField(record, "issues", []));
            end
            obj.Issues = [obj.Issues, issues];
        end

        function obj = withProject(obj, project)
            obj.Project = project;
        end

        function data = load(obj, name)
            data = obj.project().load(obj, name);
        end

        function path = save(obj, name, data)
            path = obj.project().save(obj, name, data);
        end

        function paths = dataPaths(obj, name)
            paths = obj.project().dataPaths(obj, name);
        end

        function tf = inStore(obj)
            tf = ~isempty(obj.Record);
        end

        function tf = inTable(obj)
            tf = ~isempty(obj.Row);
        end

        function values = attributes(obj)
            %attributes What DSM read from the entity's names, including ancestors' identity
            values = struct();
            if obj.inStore()
                values = obj.Record.metadata;
            end
        end

        function entries = locations(obj)
            entries = {};
            if obj.inStore()
                entries = nansen.internal.asCellOfStructs(obj.Record.locations);
            end
        end

        function entry = location(obj, dataLocation)
            entry = [];
            for candidate = obj.locations()
                if string(candidate{1}.dataLocationIdentifier) == dataLocation
                    entry = candidate{1};
                    return
                end
            end
        end

        function paths = files(obj, dataLocation, pattern)
            paths = strings(1, 0);
            entry = obj.location(dataLocation);
            if ~isempty(entry) && isfield(entry, "files") && isfield(entry.files, pattern)
                paths = reshape(string(nansen.internal.asCellstr(entry.files.(pattern))), 1, []);
            end
        end

        function codes = issueCodes(obj)
            codes = unique(string(cellfun(@(i) i.code, obj.Issues, UniformOutput=false)));
            codes = reshape(codes, 1, []);
        end

        function values = values(obj)
            %values Key, attributes and authored values in one struct; authored values win
            values = obj.Key;
            for source = {obj.attributes(), obj.Row}
                if isempty(source{1})
                    continue
                end
                for name = reshape(string(fieldnames(source{1})), 1, [])
                    values.(name) = source{1}.(name);
                end
            end
        end

        function value = get(obj, name, default)
            arguments
                obj
                name (1,1) string
                default = []
            end
            values = obj.values();
            value = nansen.internal.getField(values, name, default);
        end
    end

    methods (Access = private)
        function project = project(obj)
            if isempty(obj.Project)
                error("nansen:Entity:NoProject", ...
                    "This entity was not obtained from a project, so it cannot read or write data")
            end
            project = obj.Project;
        end
    end
end
