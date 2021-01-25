require 'kramdown'
require_relative 'kramdown_parser'

module MarkdownLint
  ##
  # Representation of the markdown document passed to rule checks
  class Doc
    ##
    # A list of raw markdown source lines. Note that the list is 0-indexed,
    # while line numbers in the parsed source are 1-indexed, so you need to
    # subtract 1 from a line number to get the correct line. The element_line*
    # methods take care of this for you.

    attr_reader :lines, :parsed, :elements, :offset

    ##
    # A Kramdown::Document object containing the parsed markdown document.

    ##
    # A list of top level Kramdown::Element objects from the parsed document.

    ##
    # The line number offset which is greater than zero when the
    # markdown file contains YAML front matter that should be ignored.

    ##
    # Create a new document given a string containing the markdown source

    def initialize(text, ignore_front_matter = false)
      regex = /^---\n(.*?)---\n\n?/m
      if ignore_front_matter && regex.match(text)
        @offset = regex.match(text).to_s.split("\n").length
        text.sub!(regex, '')
      else
        @offset = 0
      end
      # The -1 is to cause split to preserve an extra entry in the array so we
      # can tell if there's a final newline in the file or not.
      @lines = text.split(/\R/, -1)
      @parsed = Kramdown::Document.new(text, :input => 'MarkdownLint')
      @elements = @parsed.root.children
      add_annotations(@elements)
    end

    ##
    # Alternate 'constructor' passing in a filename. Exists with 1 if file
    # doesn't exist

    def self.new_from_file(filename, ignore_front_matter = false)
      if filename == '-'
        new($stdin.read, ignore_front_matter)
      elsif File.exist?(filename)
        new(File.read(filename, :encoding => 'UTF-8'), ignore_front_matter)
      else
        $stderr << "#{Errno::ENOENT}: No such file or directory - #{filename}"
        exit 1
      end
    end

    ##
    # Find all elements of a given type, returning their options hash. The
    # options hash has most of the useful data about an element and often you
    # can just use this in your rules.
    #
    #   # Returns [ { :location => 1, :element_level => 2 }, ... ]
    #   elements = find_type(:li)
    #
    # If +nested+ is set to false, this returns only top level elements of a
    # given type.

    def find_type(type, nested = true)
      find_type_elements(type, nested).map(&:options)
    end

    ##
    # Find all elements of a given type, returning a list of the element
    # objects themselves.
    #
    # Instead of a single type, a list of types can be provided instead to
    # find all types.
    #
    # If +nested+ is set to false, this returns only top level elements of a
    # given type.

    def find_type_elements(type, nested = true, elements = @elements)
      results = []
      type = [type] if type.instance_of?(Symbol)
      elements.each do |e|
        results.push(e) if type.include?(e.type)
        if nested && !e.children.empty?
          results.concat(find_type_elements(type, nested, e.children))
        end
      end
      results
    end

    ##
    # A variation on find_type_elements that allows you to skip drilling down
    # into children of specific element types.
    #
    # Instead of a single type, a list of types can be provided instead to
    # find all types.
    #
    # Unlike find_type_elements, this method will always search for nested
    # elements, and skip the element types given to nested_except.

    def find_type_elements_except(
      type, nested_except = [], elements = @elements
    )
      results = []
      type = [type] if type.instance_of?(Symbol)
      nested_except = [nested_except] if nested_except.instance_of?(Symbol)
      elements.each do |e|
        results.push(e) if type.include?(e.type)
        next if nested_except.include?(e.type) || e.children.empty?

        results.concat(
          find_type_elements_except(type, nested_except, e.children),
        )
      end
      results
    end

    ##
    # Returns the line number a given element is located on in the source
    # file. You can pass in either an element object or an options hash here.

    def element_linenumber(element)
      element = element.options if element.is_a?(Kramdown::Element)
      element[:location]
    end

    ##
    # Returns the actual source line for a given element. You can pass in an
    # element object or an options hash here. This is useful if you need to
    # examine the source line directly for your rule to make use of
    # information that isn't present in the parsed document.

    def element_line(element)
      @lines[element_linenumber(element) - 1]
    end

    ##
    # Returns a list of line numbers for all elements passed in. You can pass
    # in a list of element objects or a list of options hashes here.

    def element_linenumbers(elements)
      elements.map { |e| element_linenumber(e) }
    end

    ##
    # Returns the actual source lines for a list of elements. You can pass in
    # a list of elements objects or a list of options hashes here.

    def element_lines(elements)
      elements.map { |e| element_line(e) }
    end

    ##
    # Returns the header 'style' - :atx (hashes at the beginning), :atx_closed
    # (atx header style, but with hashes at the end of the line also), :setext
    # (underlined). You can pass in the element object or an options hash
    # here.

    def header_style(header)
      if header.type != :header
        raise 'header_style called with non-header element'
      end

      line = element_line(header)
      if line.start_with?('#')
        if line.strip.end_with?('#')
          :atx_closed
        else
          :atx
        end
      else
        :setext
      end
    end

    ##
    # Returns the list style for a list: :asterisk, :plus, :dash, :ordered or
    # :ordered_paren depending on which symbol is used to denote the list
    # item. You can pass in either the element itself or an options hash here.

    def list_style(item)
      raise 'list_style called with non-list element' if item.type != :li

      line = element_line(item).strip.gsub(/^>\s+/, '')
      if line.start_with?('*')
        :asterisk
      elsif line.start_with?('+')
        :plus
      elsif line.start_with?('-')
        :dash
      elsif line.match('[0-9]+\.')
        :ordered
      elsif line.match('[0-9]+\)')
        :ordered_paren
      else
        :unknown
      end
    end

    ##
    # Returns how much a given line is indented. Hard tabs are treated as an
    # indent of 8 spaces. You need to pass in the raw string here.

    def indent_for(line)
      line.match(/^\s*/)[0].gsub("\t", ' ' * 8).length
    end

    ##
    # Returns line numbers for lines that match the given regular expression

    def matching_lines(regex)
      @lines.each_with_index.select { |text, _linenum| regex.match(text) }
            .map do |i|
              i[1] + 1
            end
    end

    ##
    # Returns line numbers for lines that match the given regular expression.
    # Only considers text inside of 'text' elements (i.e. regular markdown
    # text and not code/links or other elements).
    def matching_text_element_lines(regex, exclude_nested = [:a])
      matches = []
      find_type_elements_except(:text, exclude_nested).each do |e|
        first_line = e.options[:location]
        # We'll error out if kramdown doesn't have location information for
        # the current element. It's better to just not match in these cases
        # rather than crash.
        next if first_line.nil?

        lines = e.value.split("\n")
        lines.each_with_index do |l, i|
          matches << first_line + i if regex.match(l)
        end
      end
      matches
    end

    ##
    # Extracts the text from an element whose children consist of text
    # elements and other things

    def extract_text(element, prefix = '', restore_whitespace = true)
      quotes = {
        :rdquo => '"',
        :ldquo => '"',
        :lsquo => "'",
        :rsquo => "'",
      }
      # If anything goes amiss here, e.g. unknown type, then nil will be
      # returned and we'll just not catch that part of the text, which seems
      # like a sensible failure mode.
      lines = element.children.map do |e|
        if e.type == :text
          e.value
        elsif %i{strong em p codespan}.include?(e.type)
          extract_text(e, prefix, restore_whitespace).join("\n")
        elsif e.type == :smart_quote
          quotes[e.value]
        end
      end.join.split("\n")
      # Text blocks have whitespace stripped, so we need to add it back in at
      # the beginning. Because this might be in something like a blockquote,
      # we optionally strip off a prefix given to the function.
      lines[0] = element_line(element).sub(prefix, '') if restore_whitespace
      lines
    end

    private

    ##
    # Adds a 'level' and 'parent' option to all elements to show how nested they
    # are

    def add_annotations(elements, level = 1, parent = nil)
      elements.each do |e|
        e.options[:element_level] = level
        e.options[:parent] = parent
        add_annotations(e.children, level + 1, e)
      end
    end
  end
end
