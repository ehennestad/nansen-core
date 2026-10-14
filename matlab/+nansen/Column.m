classdef Column
%Column One column of an entity table: name, data type, owning fragment
%
%   column = nansen.Column(name, dataType) with dataType one of
%   "string", "integer", "number", "boolean", "date", "datetime". Options:
%   Fragment (id of the fragment that owns the column), Unit, Description.

    properties
        Name (1,1) string = ""
        DataType (1,1) string {mustBeMember(DataType, ["string", "integer", "number", "boolean", "date", "datetime"])} = "string"
        Fragment (1,1) string = ""
        Unit (1,1) string = ""
        Description (1,1) string = ""
    end

    methods
        function obj = Column(name, dataType, options)
            arguments
                name (1,1) string = ""
                dataType (1,1) string = "string"
                options.Fragment (1,1) string = ""
                options.Unit (1,1) string = ""
                options.Description (1,1) string = ""
            end
            obj.Name = name;
            obj.DataType = dataType;
            obj.Fragment = options.Fragment;
            obj.Unit = options.Unit;
            obj.Description = options.Description;
        end

        function s = toStruct(obj)
            %toStruct The column as it appears in a table sidecar
            s = struct("name", char(obj.Name), "dataType", char(obj.DataType));
            if obj.Fragment ~= ""
                s.fragment = char(obj.Fragment);
            end
            if obj.Unit ~= ""
                s.unit = char(obj.Unit);
            end
            if obj.Description ~= ""
                s.description = char(obj.Description);
            end
        end
    end

    methods (Static)
        function obj = fromStruct(s)
            %fromStruct A column from a decoded sidecar or fragment column
            field = @(name) string(nansen.internal.getField(s, name, ""));
            obj = nansen.Column(string(s.name), string(s.dataType), ...
                Fragment=field("fragment"), Unit=field("unit"), Description=field("description"));
        end
    end
end
