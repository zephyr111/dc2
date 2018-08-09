import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;


// Lazy range: consume not more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
auto trackLocation(Range)(Range input, string filename)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    static struct Result
    {
        private Range _input;
        private string _filename;
        private uint _line = 1;
        private uint _col = 1;
        private ulong _pos = 0;

        this(Range input, string filename)
        {
            _input = input;
            _filename = filename;
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            return _input.front;
        }

        void popFront()
        {
            auto first = _input.front;
            _input.popFront();
            _col++;
            _pos++;

            if(first == '\n')
            {
                _line++;
                _col = 1;
            }
        }

        @property auto save()
        {
            typeof(this) result = this;
            result._input = _input.save;
            return result;
        }

        @property auto filename() { return _filename; }
        @property auto line() { return _line; }
        @property auto col() { return _col; }
        @property auto pos() { return _pos; }
    }

    return Result(input, filename);
}


