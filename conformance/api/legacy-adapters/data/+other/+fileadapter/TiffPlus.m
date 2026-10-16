classdef TiffPlus < nansen.dataio.fileadapter.imagestack.ImageStack
%TIFFPLUS A stack adapter built on dev's own ImageStack adapter, whose file types and data type it keeps.

    methods (Access = protected)
        function imageStack = readData(obj, varargin)
            imageStack = readData@nansen.dataio.fileadapter.imagestack.ImageStack(obj, varargin{:});
        end
    end
end
