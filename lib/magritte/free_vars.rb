module Magritte
  module FreeVars
    def self.scan(node)
      Scanner.new.collect(node)
    end

    class Scanner < Tree::Collector
      def visit_lex_variable(node)
        Set.new([node.name])
      end

      def visit_lambda(node)
        unless node.patterns.all? { |n| n.is_a? AST::Binder }
          raise "Not implemented yet!"
        end
        #binding.pry
        used_vars = collect_from(node.bodies)
        bound_vars = node.patterns.map(&:name)
        used_vars - bound_vars
      end
    end
  end
end