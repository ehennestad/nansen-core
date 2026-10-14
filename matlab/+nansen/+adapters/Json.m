classdef Json < nansen.FileAdapter
%Json Any JSON value
    methods
        function data = read(~, path)
            data = jsondecode(nansen.internal.readText(path));
        end

        function write(~, path, data)
            nansen.internal.writeText(path, [jsonencode(data, PrettyPrint=true), newline]);
        end
    end
end
