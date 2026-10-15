classdef ThingReader
%ThingReader A file adapter to import: a .thing file is a line of text, read as its words
    methods
        function data = read(~, path)
            data = cellstr(split(strtrim(string(fileread(path)))))';
        end

        function write(~, path, data)
            fid = fopen(path, "w");
            fprintf(fid, "%s", strjoin(string(data), " "));
            fclose(fid);
        end
    end
end
