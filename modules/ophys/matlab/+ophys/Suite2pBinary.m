classdef Suite2pBinary < nansen.FileAdapter
%Suite2pBinary suite2p's registered recording, data.bin: int16 frames of Ly x Lx in C order, one after the other
%
%   Ly and Lx are read from the ops.npy beside it: a pickled dict, whose Ly
%   and Lx are found in the pickle's bytes (suite2p keeps them as plain
%   integers); nothing in it is unpickled. Read a chunk of frames at a time,
%   as height x width x frames; frames past the last whole one are left
%   out. Read only. Python's ophys_adapters.Suite2pBinary reads the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                [ly, lx] = ophys.Suite2pBinary.frameSize(paths(i));
                listing = dir(paths(i));
                frames = floor(listing.bytes / (2 * ly * lx));
                if frames == 0
                    nansen.internal.throwError("invalid-data", "%s holds no whole %d x %d frame of int16", paths(i), ly, lx)
                end
                path = paths(i);
                % each frame in C order is a Fortran-order Lx x Ly frame: read so, then turned
                parts{i} = nansen.Stack([ly, lx, frames], "int16", @(first, last) permute(nansen.adapters.Npy.readFrames( ...
                    path, "int16", "ieee-le", [lx, ly, frames], true, 0, false, first, last), [2, 1, 3]));
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "suite2p's files are written by suite2p; save stacks in another format")
        end
    end

    methods (Static)
        function [ly, lx] = frameSize(path)
            %frameSize Ly and Lx from the ops.npy beside a data.bin
            ops = fullfile(fileparts(path), "ops.npy");
            if ~isfile(ops)
                nansen.internal.throwError("invalid-data", "%s: there is no ops.npy beside it, which has the frame size", path)
            end
            fid = fopen(ops, "r");
            data = fread(fid, Inf, "*uint8")';
            fclose(fid);
            ly = ophys.Suite2pBinary.pickledInt(data, "Ly", ops);
            lx = ophys.Suite2pBinary.pickledInt(data, "Lx", ops);
        end

        function value = pickledInt(data, key, path)
            %pickledInt The plain integer under a string key of a pickled dict, read from the pickle's opcodes
            %
            %   The key as SHORT_BINUNICODE (protocol 4 and up) or BINUNICODE
            %   (protocols 1 to 3), an optional memo opcode, then BININT1,
            %   BININT2, BININT or LONG1. As Python's ophys_adapters._pickled_int.
            name = uint8(char(key));
            prefixes = {[uint8(140), uint8(numel(name))], [uint8('X'), typecast(uint32(numel(name)), 'uint8')]};
            for p = 1:numel(prefixes)
                at = strfind(char(data), char([prefixes{p}, name]));
                if isempty(at)
                    continue
                end
                i = at(1) + numel(prefixes{p}) + numel(name);   % 1-based index of the next opcode
                switch data(i)
                    case 148            % MEMOIZE
                        i = i + 1;
                    case uint8('q')     % BINPUT
                        i = i + 2;
                    case uint8('r')     % LONG_BINPUT
                        i = i + 5;
                end
                switch data(i)
                    case uint8('K')
                        value = double(data(i + 1));
                    case uint8('M')
                        value = double(typecast(data(i + 1:i + 2), 'uint16'));
                    case uint8('J')
                        value = double(typecast(data(i + 1:i + 4), 'int32'));
                    case 138            % LONG1: n bytes, little-endian, signed
                        n = double(data(i + 1));
                        bytes = double(data(i + 2:i + 1 + n));
                        value = sum(bytes .* 256 .^ (0:n - 1));
                        if n > 0 && bytes(end) >= 128
                            value = value - 256 ^ n;
                        end
                    otherwise
                        nansen.internal.throwError("invalid-data", "%s: %s is not a plain integer", path, key)
                end
                return
            end
            nansen.internal.throwError("invalid-data", "%s has no %s", path, key)
        end
    end
end
