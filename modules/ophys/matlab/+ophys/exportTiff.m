function result = exportTiff(entity, options, context)
%exportTiff Frames firstFrame..lastFrame of the stack written to a TIFF file, a chunk at a time
%
%   As dev's imviewer exports a stack: ophys.exportStack with format tiff.
    options.format = "tiff";
    result = ophys.exportStack(entity, options, context);
end
