use colored::*;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;

#[derive(Debug, Deserialize)]
struct Config {
    functions: HashMap<String, Function>,
    models: HashMap<String, Model>,
}

#[derive(Debug, Deserialize)]
struct Function {
    #[serde(rename = "type")]
    func_type: String,
    variants: HashMap<String, Variant>,
}

#[derive(Debug, Deserialize)]
struct Variant {
    #[serde(rename = "type")]
    variant_type: String,
    model: String,
}

#[derive(Debug, Deserialize)]
struct Model {
    routing: Vec<String>,
    providers: HashMap<String, Provider>,
}

#[derive(Debug, Deserialize)]
struct Provider {
    #[serde(rename = "type")]
    provider_type: String,
    model_name: String,
    #[serde(default)]
    api_type: Option<String>,
    #[serde(default)]
    provider_tools: Vec<ProviderTool>,
}

#[derive(Debug, Deserialize)]
struct ProviderTool {
    #[serde(rename = "type")]
    tool_type: String,
}

fn main() {
    let config_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "tensorzero.toml".to_string());

    let content = fs::read_to_string(&config_path)
        .expect(&format!("Failed to read config file: {}", config_path));

    let config: Config = toml::from_str(&content)
        .expect("Failed to parse TOML");

    display_config(&config);
}

fn display_config(config: &Config) {
    println!("\n{}", "╔═══════════════════════════════════════════╗".bright_cyan());
    println!("{}", "║     TensorZero Configuration Viewer      ║".bright_cyan());
    println!("{}", "╚═══════════════════════════════════════════╝".bright_cyan());

    // Display Functions
    println!("\n{}", "📋 FUNCTIONS".bright_yellow().bold());
    println!("{}", "─".repeat(50).bright_black());

    for (func_name, func) in &config.functions {
        println!("\n  {} {}", "→".bright_green(), func_name.bright_white().bold());
        println!("    {} {}", "Type:".dimmed(), func.func_type.cyan());
        println!("    {} {}", "Variants:".dimmed(), func.variants.len().to_string().yellow());

        for (variant_name, variant) in &func.variants {
            println!("\n      {} {}", "•".bright_blue(), variant_name.white());
            println!("        {} {}", "Type:".dimmed(), variant.variant_type.cyan());
            println!("        {} {}", "Model:".dimmed(), variant.model.green());
        }
    }

    // Display Models
    println!("\n\n{}", "🤖 MODELS".bright_yellow().bold());
    println!("{}", "─".repeat(50).bright_black());

    for (model_name, model) in &config.models {
        println!("\n  {} {}", "→".bright_green(), model_name.bright_white().bold());
        println!("    {} {}", "Routing:".dimmed(), model.routing.join(", ").cyan());

        for (provider_name, provider) in &model.providers {
            println!("\n      {} {} {}", "Provider:".dimmed(), provider_name.bright_magenta(), format!("({})", provider.provider_type).dimmed());
            println!("        {} {}", "Model Name:".dimmed(), provider.model_name.green());

            if let Some(api_type) = &provider.api_type {
                println!("        {} {}", "API Type:".dimmed(), api_type.yellow());
            }

            if !provider.provider_tools.is_empty() {
                println!("        {} {}", "Tools:".dimmed(), "".to_string());
                for tool in &provider.provider_tools {
                    println!("          {} {}", "•".bright_blue(), tool.tool_type.cyan());
                }
            }
        }
    }

    println!("\n{}", "─".repeat(50).bright_black());
    println!("\n{} Functions  {} Models\n",
        format!("✓ {}", config.functions.len()).bright_green(),
        format!("✓ {}", config.models.len()).bright_green()
    );
}
