function frames = tapered(frames)
%tapered Frames (height x width x n) less their means, weighted by the taper
    frames = double(frames);
    frames = (frames - mean(frames, [1, 2])) .* ophys.internal.taper(size(frames, 1), size(frames, 2));
end
