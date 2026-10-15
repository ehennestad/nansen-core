function ops = build_ops3(db, ops)
%build_ops3 Stub of Suite2P's: the TIFF files of db.RootDir, and a results folder that the wrapper must not keep
    ops.mouse_name = db.mouse_name;
    ops.date = db.date;
    ops.expts = db.expts;
    ops.RootDir = db.RootDir;
    ops.fsroot = {dir(fullfile(db.RootDir, '*.tif'))};
    ops.CharSubDirs = '';
    ops.ResultsSavePath = fullfile(ops.ResultsSavePath, 'nansen', 'suite2p');
end
