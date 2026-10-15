function n = nFramesTiff(tiff)
%nFramesTiff The number of frames of a TIFF file (a path or an open Tiff), in place of Suite2P's own
%
%   Suite2P's nFramesTiff seeks past the last directory and takes the one
%   libtiff is left at, which newer libtiff (in recent MATLAB releases)
%   leaves at the first, so that Suite2P saw a single frame.
%   ophys.internal.runSuite2p puts this folder before Suite2P on the path
%   while it runs.
    if isa(tiff, "Tiff")
        tiff = tiff.FileName;
    end
    n = numel(imfinfo(char(tiff)));
end
