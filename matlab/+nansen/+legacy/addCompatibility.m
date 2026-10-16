function folder = addCompatibility()
%addCompatibility Put matlab/devcompat on the path: the parts of NANSEN dev that dev's session methods and file adapters call
%
%   folder = nansen.legacy.addCompatibility() adds the folder (once) and
%   returns it. It holds nansen.session.SessionMethod (with setAttributes),
%   nansen.OptionsManager and utility.parsenvpairs, written for
%   nansen.legacy.SessionShim, and nansen.dataio.FileAdapter, the base class
%   of dev's file adapters, with dev's own adapter classes they may
%   subclass (nansen.dataio.fileadapter.*, the modules' of those names),
%   which read with the adapters here (nansen.legacy.FileAdapterShim). Its +nansen merges with this one's, and has
%   nothing of the same name. It goes at the end of the path, so dev's own
%   utility package, when it is on the path, is used as it is.
    folder = string(fullfile(fileparts(fileparts(fileparts(mfilename("fullpath")))), "devcompat"));
    if ~contains(string(path), folder + pathsep) && ~endsWith(string(path), folder)
        addpath(folder, "-end");
    end
end
