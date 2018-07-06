import std.stdio;
import std.getopt;
import std.exception;
import interfaces;
import ErrorHandler;
import Lexer;
import Parser;
import SemanticAnalyser;


int main(string[] args)
{
    string inputFilename;
    auto helpInformation = getopt(args,
                                    std.getopt.config.caseSensitive,
                                    std.getopt.config.required,
                                    "input|i", "Input filename", &inputFilename);

    if(helpInformation.helpWanted)
    {
        defaultGetoptPrinter("A simple C89 compiler", helpInformation.options);
        return 1;
    }

    auto errorHandler = new ErrorHandler(inputFilename);

    try
    {
        auto lexer = new Lexer(inputFilename, errorHandler);
        auto parser = new Parser(lexer, errorHandler);
        auto semAnalyser = new SemanticAnalyser(parser, errorHandler);

        lexer.go();
    }
    catch(HaltException err)
    {
        errorHandler.handleHalt(err);
        errorHandler.printReport();
    }

    return errorHandler.countErrors > 0;
}

