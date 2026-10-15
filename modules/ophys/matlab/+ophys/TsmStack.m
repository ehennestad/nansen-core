classdef TsmStack < nansen.FileAdapter
%TsmStack A TSM file (SciMeasure / RedShirt cameras, dev's macroscope recordings)
%
%   A FITS-like header of 80-character cards in 2880-byte blocks (NAXIS1
%   columns, NAXIS2 rows, NAXIS3 frames), then int16 frames, little-endian,
%   the columns fastest, then a dark frame, which is subtracted from every
%   frame (int16 arithmetic, so saturating), as dev's TSM stack does. The
%   frame rate is 1 / EXPOSURE (seconds per frame), when the header has it.
%   Read a chunk at a time; read only. Python's ophys_adapters.TsmStack is
%   the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                [columns, rows, frames, offset, exposure] = ophys.TsmStack.header(paths(i));
                listing = dir(paths(i));
                needed = offset + (frames + 1) * rows * columns * 2;
                if listing.bytes < needed
                    nansen.internal.throwError("invalid-data", "%s is %d bytes; %d frames and a dark frame of %d x %d need %d", ...
                        paths(i), listing.bytes, frames, rows, columns, needed)
                end
                path = paths(i);
                dark = ophys.TsmStack.frames(path, offset, rows, columns, frames + 1, frames + 1, zeros(rows, columns, "int16"));
                parts{i} = nansen.Stack([rows, columns, frames], "int16", ...
                    @(a, b) ophys.TsmStack.frames(path, offset, rows, columns, a, b, dark));
                parts{i}.Metadata = ophys.internal.stackMetadata(1 / exposure);
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "TSM files are written by the camera; save stacks as TIFF")
        end
    end

    methods (Static)
        function [columns, rows, frames, offset, exposure] = header(path)
            %header Columns, rows and frames from the header cards, where the data starts, and EXPOSURE (NaN without it)
            fid = fopen(path, "r");
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot open %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            values = struct();
            offset = 0;
            done = false;
            while ~done
                block = fread(fid, 2880, "*uint8")';
                if numel(block) < 2880
                    nansen.internal.throwError("invalid-data", "%s ends inside its header (no END card)", path)
                end
                offset = offset + 2880;
                for i = 1:80:2880
                    card = char(block(i:i + 79));
                    key = strtrim(card(1:8));
                    if key == "END"
                        done = true;
                        break
                    end
                    if card(9:10) == "= " && isvarname(key)
                        values.(key) = strtrim(extractBefore(string(card(11:end)) + "/", "/"));
                    end
                end
            end
            if ~all(isfield(values, ["NAXIS1", "NAXIS2", "NAXIS3"]))
                nansen.internal.throwError("invalid-data", "%s has no NAXIS1, NAXIS2 and NAXIS3", path)
            end
            columns = str2double(values.NAXIS1);
            rows = str2double(values.NAXIS2);
            frames = str2double(values.NAXIS3);
            exposure = NaN;
            if isfield(values, "EXPOSURE")
                exposure = ophys.internal.textNumber(values.EXPOSURE);
            end
        end

        function data = frames(path, offset, rows, columns, first, last, dark)
            %frames Frames first..last (1-based) as rows x columns x count, less the dark frame
            fid = fopen(path, "r", "ieee-le");
            closer = onCleanup(@() fclose(fid));
            fseek(fid, offset + (first - 1) * rows * columns * 2, "bof");
            count = last - first + 1;
            values = fread(fid, rows * columns * count, "*int16");
            data = permute(reshape(values, columns, rows, count), [2, 1, 3]) - dark;   % int16: saturates
        end
    end
end
