classdef ThorLabsTiffs < nansen.FileAdapter
%ThorLabsTiffs A ThorImage recording: a TIFF file per frame and channel (ChanA_001_001_001_0001.tif, ...)
%
%   As dev's ThorLabsTiffs reads them: the files of each channel letter
%   are its frames, in natural order; with more than one channel the stack
%   is height x width x channels x frames, channels in letter order. Read a
%   chunk at a time. Its Metadata: frameRate and pixelSizeUM of the LSM
%   element in the Experiment.xml beside the files. Python's
%   ophys_adapters.ThorLabsTiffs reads the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = string(paths);
            letters = strings(size(paths));
            for i = 1:numel(paths)
                [~, name, ext] = fileparts(paths(i));
                token = regexp(name + ext, "^Chan([A-Z])_", "tokens", "once");
                if isempty(token)
                    nansen.internal.throwError("invalid-data", "%s is not a ThorImage frame (ChanA_..., ChanB_...)", name + ext)
                end
                letters(i) = token;
            end
            names = unique(letters);   % sorted
            channels = cell(1, numel(names));
            for k = 1:numel(names)
                channels{k} = ophys.TiffStack().open(paths(letters == names(k)));
            end
            metadata = ophys.ThorLabsTiffs.metadata(fullfile(fileparts(paths(1)), "Experiment.xml"));
            if numel(channels) == 1
                stack = channels{1};
                stack.Metadata = metadata;
                return
            end
            first = channels{1};
            for k = 2:numel(channels)
                if ~isequal(size(channels{k}), size(first)) || channels{k}.ClassName ~= first.ClassName
                    nansen.internal.throwError("invalid-data", "the channels of the recording differ in size, frames or type")
                end
            end
            [height, width, frames] = size(first);
            stack = nansen.Stack([height, width, numel(channels), frames], first.ClassName, ...
                @(a, b) ophys.ThorLabsTiffs.together(channels, a, b));
            stack.Metadata = metadata;
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "ThorImage files are written by ThorImage; save stacks as TIFF")
        end
    end

    methods (Static)
        function metadata = metadata(path)
            %metadata frameRate and pixelSizeUM of the LSM element of a ThorImage Experiment.xml; struct() without one
            metadata = struct();
            if ~isfile(path)
                return
            end
            tag = regexp(fileread(path), '<LSM\s[^>]*>', "match", "once");
            [names, values] = ophys.internal.xmlAttributes(tag);
            rate = NaN;
            pixel = NaN;
            at = find(names == "frameRate", 1, "last");
            if ~isempty(at)
                rate = ophys.internal.textNumber(values(at));
            end
            at = find(names == "pixelSizeUM", 1, "last");
            if ~isempty(at)
                pixel = ophys.internal.textNumber(values(at));
            end
            metadata = ophys.internal.stackMetadata(rate, [pixel, pixel]);
        end

        function data = together(channels, first, last)
            %together Frames first..last of every channel, as height x width x channels x frames
            parts = cellfun(@(c) permute(c.frames(first, last), [1, 2, 4, 3]), channels, UniformOutput=false);
            data = cat(3, parts{:});
        end
    end
end
