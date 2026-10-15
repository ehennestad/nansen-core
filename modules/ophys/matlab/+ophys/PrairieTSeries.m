classdef PrairieTSeries < nansen.FileAdapter
%PrairieTSeries A Bruker (Prairie View) T-series: the XML file, which lists a TIFF file (and page) per frame and channel
%
%   Reads height x width x frames, or height x width x channels x frames
%   with more than one channel, a frame at a time from its files. Read
%   only. Its Metadata: the frame rate is 1 / framePeriod and the pixel
%   size micronsPerPixel's XAxis and YAxis, of the first PVStateValue of
%   each. Python's ophys_adapters.PrairieTSeries reads the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                parts{i} = ophys.PrairieTSeries.openOne(paths(i));
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "Prairie View files are written by the microscope; save a stack with npy or ophys.tiff_stack")
        end
    end

    methods (Static, Access = private)
        function stack = openOne(path)
            text = fileread(path);
            folder = fileparts(path);
            bodies = regexp(text, '<Frame(?:\s[^>]*)?>(.*?)</Frame>', "tokens");
            files = {};   % per frame: channel numbers, file names and pages
            for f = 1:numel(bodies)
                tags = regexp(bodies{f}{1}, '<File\s[^>]*>', "match");
                channels = [];
                names = strings(0);
                pages = [];
                for t = 1:numel(tags)
                    pairs = regexp(tags{t}, '(\w+)="([^"]*)"', "tokens");
                    keys = cellfun(@(p) string(p{1}), pairs);
                    values = cellfun(@(p) string(p{2}), pairs);
                    if any(keys == "channel") && any(keys == "filename")
                        channels(end + 1) = str2double(values(find(keys == "channel", 1))); %#ok<AGROW>
                        names(end + 1) = values(find(keys == "filename", 1)); %#ok<AGROW>
                        page = 1;
                        if any(keys == "page")
                            page = str2double(values(find(keys == "page", 1)));
                        end
                        pages(end + 1) = page; %#ok<AGROW>
                    end
                end
                if ~isempty(channels)
                    [channels, order] = sort(channels);
                    files{end + 1} = struct("channels", channels, "names", names(order), "pages", pages(order)); %#ok<AGROW>
                end
            end
            if isempty(files)
                nansen.internal.throwError("invalid-data", "%s lists no frames (not a Prairie View T-series)", path)
            end
            channels = files{1}.channels;
            if any(cellfun(@(f) ~isequal(f.channels, channels), files))
                nansen.internal.throwError("invalid-data", "%s: the frames do not all have channels %s", path, mat2str(channels))
            end
            first = ophys.PrairieTSeries.page(fullfile(folder, files{1}.names(1)), files{1}.pages(1));
            count = numel(channels);
            if count == 1
                dimensions = [size(first), numel(files)];
            else
                dimensions = [size(first), count, numel(files)];
            end
            stack = nansen.Stack(dimensions, class(first), @(a, b) ophys.PrairieTSeries.frames(folder, files, first, count, a, b));
            stack.Metadata = ophys.PrairieTSeries.metadata(text);
        end

        function metadata = metadata(text)
            %metadata frameRate (1 / framePeriod) and pixelSize (micronsPerPixel's XAxis and YAxis) of a Prairie View XML file
            period = NaN;
            tag = regexp(text, '<PVStateValue\s[^>]*key="framePeriod"[^>]*>', "match", "once");
            [names, values] = ophys.internal.xmlAttributes(tag);
            at = find(names == "value", 1, "last");
            if ~isempty(at)
                period = ophys.internal.textNumber(values(at));
            end
            perPixel = struct("XAxis", NaN, "YAxis", NaN);
            seen = strings(0);
            body = regexp(text, '<PVStateValue\s[^>]*key="micronsPerPixel"[^>]*>(.*?)</PVStateValue>', "tokens", "once");
            if ~isempty(body)
                for tag = regexp(body{1}, '<IndexedValue\s[^>]*>', "match")
                    [names, values] = ophys.internal.xmlAttributes(tag{1});
                    index = find(names == "index", 1, "last");
                    value = find(names == "value", 1, "last");
                    if isempty(index) || isempty(value) || any(seen == values(index))
                        continue
                    end
                    seen(end + 1) = values(index); %#ok<AGROW>
                    if isfield(perPixel, values(index))
                        perPixel.(values(index)) = ophys.internal.textNumber(values(value));
                    end
                end
            end
            metadata = ophys.internal.stackMetadata(1 / period, [perPixel.XAxis, perPixel.YAxis]);
        end

        function data = frames(folder, files, first, count, a, b)
            data = zeros([size(first), count, b - a + 1], "like", first);
            for t = a:b
                for c = 1:count
                    data(:, :, c, t - a + 1) = ophys.PrairieTSeries.page(fullfile(folder, files{t}.names(c)), files{t}.pages(c));
                end
            end
            if count == 1
                data = reshape(data, size(first, 1), size(first, 2), b - a + 1);
            end
        end

        function data = page(path, number)
            warning("off", "imageio:tiffmexutils:libtiffWarning");
            warning("off", "MATLAB:imagesci:tiffmexutils:libtiffWarning");
            file = Tiff(char(path), "r");
            closer = onCleanup(@() close(file));
            file.setDirectory(number);
            data = file.read();
        end
    end
end
