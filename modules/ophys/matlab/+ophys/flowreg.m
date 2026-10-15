function result = flowreg(entity, options, context)
%flowreg Non-rigid motion correction with the Flow-Registration toolbox, when it is on the path
    if exist("OF_options", "file") ~= 2 || exist("compensate_recording", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.flowreg needs Flow-Registration on the MATLAB path: https://github.com/FlowRegSuite/flow_registration")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    frames = size(stack, 3);
    folder = string(tempname);
    mkdir(folder);
    cleanup = onCleanup(@() rmdir(folder, "s"));
    input = fullfile(folder, "input.tif");
    ophys.TiffStack().write(input, stack);
    % char throughout: Flow-Registration builds file names with ['compensated.' output_format]
    settings = feval("OF_options", 'input_file', char(input), 'output_path', char(fullfile(folder, "out")), ...
        'output_format', 'TIFF', 'alpha', double(options.alpha), 'quality_setting', char(options.quality), ...
        'reference_frames', 1:min(options.referenceFrames, frames));
    context.log("%s: running Flow-Registration on %d frames", ophys.internal.entityName(entity), frames);
    feval("compensate_recording", settings);
    written = [dir(fullfile(folder, "out", "**", "*.tif")); dir(fullfile(folder, "out", "**", "*.TIFF")); dir(fullfile(folder, "out", "**", "*.tiff"))];
    if isempty(written)
        nansen.internal.throwError("invalid-data", "Flow-Registration wrote no TIFF file in %s", fullfile(folder, "out"))
    end
    aligned = ophys.TiffStack().read(fullfile(written(1).folder, written(1).name));
    ophys.internal.saveIf(context, entity, options.output, cast(aligned, class(stack)));
    result = struct("frames", size(aligned, 3));
end
