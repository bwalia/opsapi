#!/usr/bin/env python3
import os
import sys
import re

def render_template(template_file, output_file=None, env_file=None):
    """
    Replace ${{VAR_NAME}} placeholders with environment variable values.
    
    Args:
        template_file: Path to the template file
        output_file: Path to output file (default: removes -template from filename)
        env_file: Optional .env file to load additional variables
    """
    
    # Load additional environment variables from .env file if provided
    if env_file and os.path.exists(env_file):
        with open(env_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    # Don't override existing env vars
                    if key not in os.environ:
                        os.environ[key] = value
    
    # Read template file
    with open(template_file, 'r') as f:
        content = f.read()
    
    # Find all ${{VAR_NAME}} patterns
    pattern = r'\$\{\{([A-Z_][A-Z0-9_]*)\}\}'
    
    def replace_var(match):
        var_name = match.group(1)
        value = os.environ.get(var_name)
        
        if value is None:
            print(f"Warning: Environment variable '{var_name}' not found, leaving as-is", file=sys.stderr)
            return match.group(0)  # Return original placeholder
        
        return value
    
    # Replace all placeholders
    rendered = re.sub(pattern, replace_var, content)
    
    # Determine output file
    if output_file is None:
        if '-template' in template_file:
            output_file = template_file.replace('-template', '')
        else:
            output_file = template_file.replace('.template', '')
    
    # Write output
    with open(output_file, 'w') as f:
        f.write(rendered)
    
    print(f"Template rendered: {template_file} -> {output_file}")
    return output_file

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 render_config.py <template_file> [output_file] [.env_file]")
        print("\nExample:")
        print("  python3 render_config.py nginx-values-template.conf")
        print("  python3 render_config.py nginx-values-template.conf nginx.conf")
        print("  python3 render_config.py nginx-values-template.conf nginx.conf .env")
        sys.exit(1)
    
    template_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None
    env_file = sys.argv[3] if len(sys.argv) > 3 else '.env'
    
    if not os.path.exists(template_file):
        print(f"Error: Template file '{template_file}' not found", file=sys.stderr)
        sys.exit(1)
    
    try:
        render_template(template_file, output_file, env_file)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()