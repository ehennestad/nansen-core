function result = deepInterpolation(entity, options, context)
%deepInterpolation Denoise the stack with DeepInterpolation-MATLAB and a trained model, as dev's Denoiser
%
%   Each frame is predicted by deepinterp.Net's interp from preFrames
%   before and postFrames after it, leaving omittedFrames out on either side
%   (deepinterp's Nomit, 2 x omittedFrames + 1, counts the predicted frame
%   too); frames too close to the start or end to be predicted are kept as
%   they were. The model is a Keras .h5 file (deepinterp's KerasFile: the
%   Deep Learning Toolbox and its Converter for TensorFlow Models) or a
%   .mat file holding a Deep Learning Toolbox network as net (deepinterp's
%   matlab). The stack is centred and scaled by one mean and standard
%   deviation for all its pixels, as DeepInterpolation's OphysGenerator in
%   Python and its pretrained two-photon models (dev's Denoiser scaled each
%   pixel by its own), and frames smaller than the network's input are put
%   in its middle, as dev's Denoiser did for the pretrained 512 x 512
%   models. Saved as single, as Python's ophys_methods.deep_interpolation.
    if exist("deepinterp.Net", "class") ~= 8
        nansen.internal.throwError("dependency-missing", ...
            "ophys.deep_interpolation needs DeepInterpolation-MATLAB on the MATLAB path: " + ...
            "https://github.com/MATLAB-Community-Toolboxes-at-INCF/DeepInterpolation-MATLAB")
    end
    model = string(options.modelPath);
    if ~isfile(model)
        nansen.internal.throwError("invalid-options", "there is no model file %s", model)
    end
    [~, ~, extension] = fileparts(model);
    if lower(extension) ~= ".mat" && exist("importKerasLayers", "file") == 0
        nansen.internal.throwError("dependency-missing", ...
            "ophys.deep_interpolation reads a Keras model with the Deep Learning Toolbox Converter for TensorFlow Models")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack, 1:3);
    pre = double(options.preFrames);
    post = double(options.postFrames);
    omitted = double(options.omittedFrames);
    before = pre + omitted;
    after = post + omitted;
    if frames <= before + after
        nansen.internal.throwError("invalid-data", "%d frames are too few for %d frames around each predicted one", ...
            frames, before + after)
    end
    if lower(extension) == ".mat"
        kind = 'matlab';
    else
        kind = 'KerasFile';
    end
    net = deepinterp.Net(kind, 'file', char(model), 'Npre', pre, 'Npost', post, 'Nomit', 2 * omitted + 1);
    rows = net.N;
    columns = net.M;
    if isnan(rows) || isnan(columns)
        rows = height;
        columns = width;
    end
    if height > rows || width > columns
        nansen.internal.throwError("invalid-data", "the model takes frames of %d x %d pixels; the stack's are %d x %d", ...
            rows, columns, height, width)
    end
    top = floor((rows - height) / 2);
    left = floor((columns - width) / 2);
    % one mean and standard deviation (of the population, as NumPy's) for all pixels
    total = 0;
    squares = 0;
    for t = 1:frames
        frame = double(stack(:, :, t));
        total = total + sum(frame, "all");
        squares = squares + sum(frame .^ 2, "all");
    end
    count = height * width * frames;
    average = total / count;
    deviation = sqrt(max(0, squares / count - average ^ 2));
    if deviation == 0
        deviation = 1;
    end
    out = single(stack);
    context.log("%s: running DeepInterpolation on %d frames", ophys.internal.entityName(entity), frames);
    step = 200;
    for first = before + 1:step:frames - after
        context.checkCancelled();
        last = min(first + step - 1, frames - after);
        window = (first - before):(last + after);   % the frames predicted and those around them
        input = zeros(rows, columns, numel(window), "single");
        input(top + (1:height), left + (1:width), :) = (single(stack(:, :, window)) - average) / deviation;
        predicted = net.interp(input, 'progbar', false);
        part = predicted(top + (1:height), left + (1:width), before + 1:before + 1 + last - first);
        out(:, :, first:last) = single(double(part) * deviation + average);
        context.progress((last - before) / (frames - before - after), sprintf("frame %d/%d", last, frames));
    end
    ophys.internal.saveIf(context, entity, options.output, out);
    result = struct("frames", frames, "height", height, "width", width, "predicted", frames - before - after);
end
