function value = readPickledNpy(path)
%readPickledNpy The value of a .npy file of objects (NumPy's allow_pickle), as suite2p's stat.npy, without Python
%
%   The pickle after the .npy header is read by ophys.internal.unpickle,
%   which runs nothing in it: an array of dicts reads as a cell array of
%   structs. A .npy file of numbers is read by nansen.adapters.Npy. As
%   Python's ophys_adapters.read_pickled_npy.
    fid = fopen(path, "r", "ieee-le");
    if fid < 0
        nansen.internal.throwError("cannot-open", "cannot open %s", path)
    end
    closer = onCleanup(@() fclose(fid));
    magic = fread(fid, 6, "*uint8")';
    if ~isequal(magic, uint8([147, 'NUMPY']))
        nansen.internal.throwError("invalid-data", "%s is not a .npy file", path)
    end
    version = fread(fid, 2, "*uint8")';
    if version(1) == 1
        headerLength = double(fread(fid, 1, "uint16"));
    else
        headerLength = double(fread(fid, 1, "uint32"));
    end
    header = char(fread(fid, headerLength, "*uint8")');
    descr = regexp(header, "'descr'\s*:\s*'([^']*)'", "tokens", "once");
    if isempty(descr)
        nansen.internal.throwError("invalid-data", "%s has a .npy header this reader does not understand", path)
    end
    if ~ismember(descr{1}, {'|O', 'O'})
        clear closer
        value = nansen.adapters.Npy().read(path);
        return
    end
    bytes = fread(fid, Inf, "*uint8")';
    try
        value = ophys.internal.unpickle(bytes, path);
    catch error_
        if isa(error_, "nansen.NansenError")
            rethrow(error_)
        end
        nansen.internal.throwError("invalid-data", "%s: its objects cannot be read (%s)", path, error_.message)
    end
end
