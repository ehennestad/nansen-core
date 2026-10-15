function value = textNumber(text)
%textNumber A number in a file's text (a decimal comma too); NaN when it is not one, as Python's ophys_adapters._number
    value = str2double(strrep(string(text), ",", "."));
end
