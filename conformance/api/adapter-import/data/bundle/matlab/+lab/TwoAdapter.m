classdef TwoAdapter < nansen.FileAdapter
%TwoAdapter A file adapter of a module's layout, to import: the first two words of each line
    methods
        function data = read(~, path)
            lines = splitlines(strtrim(string(fileread(path))));
            data = cell(numel(lines), 1);
            for k = 1:numel(lines)
                words = split(lines(k))';
                data{k} = cellstr(words(1:min(2, numel(words))));
            end
        end

        function write(~, path, data)
            fid = fopen(path, "w");
            for k = 1:numel(data)
                fprintf(fid, "%s\n", strjoin(string(data{k}), " "));
            end
            fclose(fid);
        end
    end
end
