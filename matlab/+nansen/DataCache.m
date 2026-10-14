classdef DataCache < handle
%DataCache Loaded data kept in memory, as dev's nansen.cache.DataCache keeps it
%
%   dev's cache is one per MATLAB session. Here each project has its own
%   (project.DataCache), since the core keeps no global state. An entry is
%   the data read from one file. Each entry is stored with the file's
%   modification time and size, so a file changed on disk is read again.
%   project.save also drops the entry of the file it writes. The cache keeps
%   the least recently used entries out when it would go over its budget
%   (2 GiB unless set). Python's nansen.cache does the same.
%
%   MATLAB values are copied when changed, so a caller cannot change what
%   is kept. Handle objects are the exception: they are shared.

    properties (Constant)
        DefaultMaxBytes = 2 * 2^30
    end

    properties
        MaxBytes (1,1) double = nansen.DataCache.DefaultMaxBytes
    end

    properties (SetAccess = private)
        Bytes (1,1) double = 0
        Hits (1,1) double = 0
        Misses (1,1) double = 0
        Evictions (1,1) double = 0
    end

    properties (Access = private)
        Entries   % containers.Map: key -> struct(Signature, Value, Bytes, Used)
        Clock (1,1) double = 0   % gives each use a later number, for least recently used
    end

    methods
        function obj = DataCache(maxBytes)
            arguments
                maxBytes (1,1) double = nansen.DataCache.DefaultMaxBytes
            end
            obj.MaxBytes = maxBytes;
            obj.Entries = containers.Map("KeyType", "char", "ValueType", "any");
        end

        function value = getOrLoad(obj, key, signature, loader)
            %getOrLoad The value kept for key if it was kept with this signature, else loader()'s value, now kept
            key = char(key);
            if isKey(obj.Entries, key)
                entry = obj.Entries(key);
                if isequal(entry.Signature, signature)
                    obj.Clock = obj.Clock + 1;
                    entry.Used = obj.Clock;
                    obj.Entries(key) = entry;
                    obj.Hits = obj.Hits + 1;
                    value = entry.Value;
                    return
                end
            end
            obj.Misses = obj.Misses + 1;
            value = loader();
            bytes = nansen.DataCache.sizeOf(value);
            obj.remove(key);
            if bytes > obj.MaxBytes
                return   % given, not kept
            end
            while obj.Bytes + bytes > obj.MaxBytes
                keys = obj.Entries.keys();
                used = cellfun(@(entry) entry.Used, obj.Entries.values(keys));
                [~, oldest] = min(used);
                obj.remove(keys{oldest});
                obj.Evictions = obj.Evictions + 1;
            end
            obj.Clock = obj.Clock + 1;
            obj.Entries(key) = struct("Signature", {signature}, "Value", {value}, "Bytes", bytes, "Used", obj.Clock);
            obj.Bytes = obj.Bytes + bytes;
        end

        function remove(obj, key)
            key = char(key);
            if isKey(obj.Entries, key)
                entry = obj.Entries(key);   % a containers.Map takes one level of indexing
                obj.Bytes = obj.Bytes - entry.Bytes;
                obj.Entries.remove(key);
            end
        end

        function removeAll(obj)
            obj.Entries = containers.Map("KeyType", "char", "ValueType", "any");
            obj.Bytes = 0;
        end

        function counts = stats(obj)
            counts = struct("entries", double(obj.Entries.Count), "bytes", obj.Bytes, "maxBytes", obj.MaxBytes, ...
                "hits", obj.Hits, "misses", obj.Misses, "evictions", obj.Evictions);
        end
    end

    methods (Static)
        function bytes = sizeOf(value) %#ok<INUSD>
            %sizeOf Bytes a value holds, as whos counts them (handle objects only roughly)
            info = whos("value");
            bytes = info.bytes;
        end
    end
end
