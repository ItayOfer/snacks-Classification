## Welcome
##Welcome to the notebook for model $2$ of our final project. In this model, which serves as our second try, the main changes from model $1$ is the expanded feature engineering from the tabular data, as-well as an extended use of the results from the finetuned MobileNetV2 model. 
##We included as features the full results from the finetuned MobileNetV2 model, i.e. sigmoid outputs for each of the categories.
##We also engineered for each snack the ranks of the categories' sigmoids (ranks in increasing order).
##The code for the finetuned MobileNetV2 model is in the python notebook.

## Required libraries

library(tidyverse)
library(tidymodels)
if (!require("xgboost")) {
  install.packages("xgboost")
}
library(xgboost)


## Data preparation 
##To begin, we will first read the data and clean it up a bit, making it more suitable for modelling tools.

food_train <- read_csv("./data/food_train.csv") %>% 
  mutate(ingredients = ifelse(is.na(ingredients), "", ingredients)) # Remove NAs
nutrients <- read_csv("./data/nutrients.csv")
food_nutrients <- read_csv("./data/food_nutrients.csv")
image_data <- read_csv("./data/image_data.csv")


##We'll combine the datasets into a unified dataframe:

# Renaming the categories with shorter names:
food_train <- food_train %>% mutate(category = case_when(
  category == "cookies_biscuits" ~ "cookie",
  category == "cakes_cupcakes_snack_cakes" ~ "cake",
  category == "chips_pretzels_snacks" ~ "savory",
  category == "popcorn_peanuts_seeds_related_snacks" ~ "seeds",
  TRUE ~ category
))

# Used full names of nutrients and matched the nutrients found in each product 
nutrients$fullname <- paste0(nutrients$name, " in ", nutrients$unit_name)
food_nutrients <- left_join(food_nutrients, select(nutrients, nutrient_id, fullname), 
                            by="nutrient_id")
food_nutrients <- pivot_wider(food_nutrients, id_cols="idx", names_from="fullname", 
                              values_from="amount")
food_nutrients <- food_nutrients %>%
  mutate(across(everything(), ~ifelse(is.na(.), 0, .)))



##An important note is that by unifying the two tables, many nutrients (more than $75\%$) were dropped since they do not appear in any product.

# Unified all of the data with the nutrient features
# Removed the index and the redundant serving_size_unit (treating all as gram)
food_train <- left_join(food_train, food_nutrients, by="idx")
food_train <- left_join(food_train, image_data, by="idx")
nutrients_names <- colnames(food_train)[-c(1:8, 57:68)] # To be used later for nutrient feature extraction


##We'll split the training data to different samples for each step of the modelling process.

tidymodels_prefer()

# Set aside 10% to use for validation
set.seed(42)
val_split <- initial_split(food_train, prop = 0.1) 
val <- training(val_split)
food_train <- testing(val_split)

# Set aside 30% to use for model tuning
set.seed(42)
tuning_split <- initial_split(food_train, prop = (1/3)) 
tuning <- training(tuning_split)

# 60% to use for feature engineering
eng <- testing(tuning_split)


## Feature Engineering
### Extracting features from household unit

# Taking top indicative words
unit_words <- paste(eng$household_serving_fulltext, collapse = " ")
unit_words <- gsub("[[:punct:]0-9]", "", unit_words)
unit_words <- unlist(strsplit(unit_words, " "))
unit_words <- gsub("s$", "", unit_words)
unit_words <- table(unit_words)
unit_words <- data.frame(word = names(unit_words), freq = as.vector(unit_words))
unit_words <- unit_words %>% 
  filter(!word %in% c("", "mini", "serving", "oz", "ounce", 
                      "onz", "grm", "|", "about", "of", "per", "approx")) %>%
  filter(freq >= 15) # More then 95% of all sentences

unit_features <- function(data) {
  data <- data %>% 
    rename(house = household_serving_fulltext) %>%
    mutate(house = tolower(house))
  for (word in unit_words$word) {
    data <- cbind(data, data.frame(ifelse(grepl(word, data$house), 1, 0)))
    names(data)[ncol(data)] <- paste("u_", word)
  }
  data <- data %>% select(-house)
  return (data)
}


### Extracting features from brand

# Taking commonsense words - top appearing words are not indicative!
brand_words <- c("sweet", "snack", "bak", "cand", "choco", "cook", "cake", "biscuit",
                 "jelly", "nut", "nestle", "reese", "snyder", "pop", "corn", "pie", 
                 "potato", "cream", "licorice", "savory", "nutella", "doughnut", 
                 "coffee", "cafe", "pretzel", "treat", "dessert", "starbucks", 
                 "loacker", "taffy", "chip", "ritter", "lindt")

brand_features <- function(data) {
  data <- data %>% 
    mutate(brand = tolower(brand))
    for (word in brand_words) {
      data <- cbind(data, data.frame(ifelse(grepl(word, data$brand), 1, 0)))
      names(data)[ncol(data)] <- paste("b_", word)
    }
    data <- data %>% select(-brand)
    return (data)
}


### Extracting top nutrients

nutrient_features <- function(data, k){ # Extract top nutrients in terms of average frequency
  column_averages <- data %>% 
    select(all_of(nutrients_names)) %>%
    summarise(across(where(is.numeric), mean))
  
  top_columns <- column_averages %>%
    pivot_longer(everything(), names_to = "column", values_to = "average") %>%
    arrange(desc(average)) %>%
    slice_head(n = k) %>%
    pull(column)
  
  data <- data %>% select(-setdiff(nutrients_names, top_columns))
  return (data)
}


### Extracting features from description

# Taking top indicative words
common_desc_words <- c("oil", "nougat", "vinegar", "rice", "multigrain", "icing", 
                       "granola", "ranch", "sriracha", "baking", "mango", "choco", 
                       "smore", "chocolatey", "fruity", "nacho", "vegetable", "chocolaty", 
                       "nugget", "barbecue", "bacon", "esperesso", "garlic", "seasoned", 
                       "olive", "greek", "hawaiian", "pineapple", "sesame", "barbeque", 
                       "spiced", "smoked", "chunky", "fish", "tea", "savory", "chickpea", 
                       "superfood", "bake", "oven", "ice", "beer", "dark chocolate", "brwnie",
                       "caramel", "fudge", "danish", "snickers", "toffee", "m&m", "peanut",
                       "marshmallow", "bark")

desc_words <- paste(eng$description, collapse = " ")
desc_words <- gsub("[[:punct:]0-9]", "", desc_words)
desc_words <- unlist(strsplit(desc_words, " "))
desc_words <- gsub("s$", "", desc_words)
desc_words <- table(desc_words)
desc_words <- data.frame(word = names(desc_words), freq = as.vector(desc_words))
desc_words <- desc_words %>% 
  filter(!word %in% c("", "with", "food", "and", "the", "original", "in", 
                      "natural", "market", "of", "classic", "deluxe", "meijer",
                      "giant", "co", "n", "value", "nature", "a", "good", "rich",
                      "valley", "fashioned", "farm", "select", "big", "wegman",
                      "all", "size", "everyday", "russell", "wei", "extra",
                      "spartan", "wild", "made", "pound", "country", "kroger",
                      "to", "top", "target", "fine", "triple", "california")) %>%
  filter(freq >= 50 | word %in% common_desc_words) # More then 70% of all sentences

desc_features <- function(data) {
  data <- data %>% 
    rename(desc = description) %>%
    mutate(desc = tolower(desc))
  for (word in desc_words$word) {
    data <- cbind(data, data.frame(ifelse(grepl(word, data$desc), 1, 0)))
    names(data)[ncol(data)] <- paste("d_", word)
  }
  data <- data %>% select(-desc)
  return (data)
}


### Extracting features from ingredients

# Taking top indicative words, after some cleanup
ing_words <- paste(eng$ingredients, collapse = " ")
ing_words <- gsub("\\(", ",", ing_words)
ing_words <- gsub("\\)", ",", ing_words)
ing_words <- gsub("\\*", "", ing_words)
ing_words <- gsub("and ", "", ing_words)
ing_words <- gsub("\\[", "", ing_words)
ing_words <- gsub("\\]", "", ing_words)
ing_words <- gsub("\\{", "", ing_words)
ing_words <- gsub("\\}", "", ing_words)
ing_words <- table(unlist(strsplit(ing_words, "[,;]\\s*|,")))
ing_words <- data.frame(word = names(ing_words),
                        freq = as.vector(ing_words)) %>%
  filter(!word %in% c("", " ")) %>%
  mutate(word = ifelse(grepl("sugar", word), "sugar", word)) %>%
  mutate(word = ifelse(grepl("flavor", word), "flavor", word)) %>%
  mutate(word = ifelse(grepl("flavor", word), "flavor", word)) %>%
  mutate(word = ifelse(grepl(
                        "contains one or more of the following: corn", word), 
                        "corn", word)) %>%
  mutate(word = ifelse(grepl(
                        "may contain one or more of the following: corn", word), 
                        "corn", word)) %>%
  mutate(word = ifelse(grepl("corn syrup", word), "corn syrup", word)) %>%
  mutate(word = ifelse(grepl("corn starch", word), "cornstarch", word)) %>%
  mutate(word = ifelse(grepl("cornstarch", word), "cornstarch", word)) %>%
  mutate(word = ifelse(grepl("lecithin", word), "soy lecithin", word)) %>%
  mutate(word = ifelse(grepl("vanil", word), "vanilla", word)) %>%
  mutate(word = ifelse(grepl("salt", word), "salt", word)) %>%
  mutate(word = ifelse(grepl("almond", word), "almond", word)) %>%
  mutate(word = ifelse(grepl("peanut", word), "peanut", word)) %>%
  mutate(word = ifelse(grepl("butter", word), "butter", word)) %>%
  mutate(word = ifelse(grepl("color", word), "color", word)) %>%
  mutate(word = ifelse(grepl("whey", word), "whey", word)) %>%
  mutate(word = ifelse(grepl("cocoa", word), "cocoa", word)) %>%
  mutate(word = ifelse(grepl("canola", word), "canola oil", word)) %>%
  mutate(word = ifelse(grepl("egg", word), "eggs", word)) %>%
  mutate(word = ifelse(grepl("milk", word), "milk", word)) %>%
  mutate(word = ifelse(grepl("dark chocolate", word), "darkchoco", word)) %>%
  mutate(word = ifelse(grepl("chocolate chips", word), "chocochips", word)) %>%
  mutate(word = ifelse(grepl("chocolate", word), "chocolate", word)) %>%
  mutate(word = ifelse(grepl("leavening", word), "leavening", word)) %>%
  mutate(word = ifelse(grepl("wheat", word), "wheat", word)) %>%
  mutate(word = ifelse(grepl("apple", word), "apple", word)) %>%
  mutate(word = ifelse(grepl("onion", word), "onion", word)) %>%
  mutate(word = ifelse(grepl("garlic", word), "garlic", word)) %>%
  mutate(word = ifelse(grepl("paprika", word), "paprika", word)) %>%
  mutate(word = ifelse(grepl("cashew", word), "cashew", word)) %>%
  mutate(word = ifelse(grepl("macad", word), "macadamia", word)) %>%
  mutate(word = ifelse(grepl("pecan", word), "pecan", word)) %>%
  mutate(word = ifelse(grepl("honey", word), "honey", word)) %>%
  mutate(word = ifelse(grepl("potato", word), "potato", word)) %>%
  mutate(word = ifelse(grepl("gum", word), "gum", word)) %>%
  mutate(word = ifelse(grepl("lemon", word), "lemon", word)) %>%
  mutate(word = ifelse(grepl("rice", word), "rice", word)) %>%
  mutate(word = ifelse(grepl("palm", word), "palm", word)) %>%
  mutate(word = ifelse(grepl("maple", word), "maple", word)) %>%
  mutate(word = ifelse(grepl("banana", word), "banana", word)) %>%
  mutate(word = ifelse(grepl("tapioca", word), "tapioca", word)) %>%
  mutate(word = ifelse(grepl("blueberr", word), "blueberry", word)) %>%
  mutate(word = ifelse(grepl("carrot", word), "carrot", word)) %>%
  mutate(word = ifelse(grepl("pepper", word), "pepper", word)) %>%
  mutate(word = ifelse(grepl("toffee", word), "toffee", word)) %>%
  mutate(word = ifelse(grepl("vinegar", word), "vinegar", word)) %>%
  mutate(word = ifelse(grepl("cacao", word), "cacao", word)) %>%
  mutate(word = ifelse(grepl("vinegar", word), "vinegar", word)) %>%
  mutate(word = ifelse(grepl("chili", word), "chili", word)) %>%
  mutate(word = ifelse(grepl("pretzel", word), "pretzel", word)) %>%
  mutate(word = ifelse(grepl("marsh", word), "marshmellow", word)) %>%
  group_by(word) %>%
  summarise(freq = sum(freq)) %>%
  filter(freq >= 30) # More then 90% of all sentences

ing_features <- function(data) {
  data <- data %>% 
    rename(ing = ingredients) %>%
    mutate(ing = tolower(ing))
  for (word in ing_words$word) {
    data <- cbind(data, data.frame(ifelse(grepl(word, data$ing), 1, 0)))
    names(data)[ncol(data)] <- paste("i_", word)
  }
  data <- data %>% select(-ing)
  return (data)
}


### Putting it all together

full_features <- function(data, k=12) {
  data <- data %>% unit_features() %>% brand_features() %>%
          nutrient_features(k = k) %>% desc_features() %>% ing_features() %>% 
          select(-c(idx, serving_size_unit))
  return (data)
}


## Model Tuning
### Gradient Boosted Trees
##The model family of choice is gradient boosted trees. We will tune the hyperparameters using a $5$-fold cross-validation. 

tuning_engd <- full_features(tuning)
cv_splits <- vfold_cv(tuning_engd, v=5)



rec <- recipe(category ~., data=tuning_engd)
mod <- boost_tree(mode="classification", engine="xgboost", trees=tune(),
                  learn_rate=tune(), sample_size=tune())
param_grid <- expand_grid(trees=c(25, 75, 100), 
                          learn_rate=c(0.001, 0.005, 0.01), 
                          sample_size=c(0.25, 0.5, 0.75))



tune_res <- tune_grid(object=mod, preprocessor=rec, resamples=cv_splits, grid=param_grid,
                      metrics=metric_set(accuracy), control=control_grid(verbose=TRUE))
collected_metrics <- collect_metrics(tune_res)


## Testing against validation set
### Baseline model and comparison function

baseline_model <- function(data) {
  popcorn_peanuts_keywords <- str_c(c("almonds", "mix", "cashews", "popcorn", 
                                      "seeds", "nuts", "macadamias", "peanuts", "corn", 
                                      "nutty", "pistachios"), collapse = "|")
  candy_keywords <- str_c(c("gummi", "gummy", "lolli", "candy", "candies", "fruit", 
                          "licorice", "drops", "confection", "chicks", "sour", "sweet", 
                          "peeps", "jelly", "dragee", "fizz", "patties", "cane"), 
                          collapse = "|")
  coockies_keywords <- str_c(c("cookie", "gingernread", "chocolate chip", "macarons", 
                             "sticks", "wafers"), collapse = "|")
  chips_keywords <- str_c(c("chips", "pretzel", "tortilla"), collapse = "|")
  chcolate_keywords <- str_c(c("chocolate", "bar"), collapse = "|")
  cakes_keywords <- str_c(c("cake", "brownie", "pie", "eclair", 
                          "donut"), collapse = "|")

  predict_category <- function(description) {
    if (str_detect(description, popcorn_peanuts_keywords)) {
      return ("seeds")
    }
    if (str_detect(description, candy_keywords)) {
      return ("candy")
    }
    if (str_detect(description, coockies_keywords)) {
      return ("cookie")
    }
    if (str_detect(description, chips_keywords)) {
      return ("savory")
    }
    if (str_detect(description, chcolate_keywords)) {
      return ("chocolate")
    }
    if (str_detect(description, cakes_keywords)) {
      return ("cakes")
    }
    return ("seeds")
  }
  pred <- map_chr(data$description, predict_category)
  return (pred)
}

score_comparison <- function(score, baseline) {
  return (score/baseline)
}


### Gather data

train <- bind_rows(eng, tuning)
train_ready <- full_features(train)
rec <- recipe(category ~., data=train_ready) %>%
       prep(train_ready)
train_ready <- rec %>% bake(train_ready)

val_ready <- full_features(val)
val_ready <- rec %>% bake(val_ready)


### Model of choice
##After evaluating the hyperparameters, we figured more trees result in better performance and thus chose to increase their amount. 

set.seed(42)
mod <- boost_tree(mode="classification", engine="xgboost", trees=300,
                  learn_rate=0.01, sample_size=0.75) %>% fit(category ~ ., data=train_ready)


### Assess Performance on validation set

pred <- mod %>% predict(new_data=val_ready)
mod_acc <- mean(pred == val$category)
mod_acc

baseline_pred <- baseline_model(val)
baseline_acc <- mean(baseline_pred == val$category)
baseline_acc

# Assuming 60% accuracy on actual test set with the baseline model, 
# the following result is the expected accuracy of our model on the test set
0.6*score_comparison(mod_acc, baseline_acc) 
```

## Predict on test set
### Gather training data

train_ready <- full_features(food_train)
rec <- recipe(category ~., data=train_ready) %>%
       prep(train_ready)
train_ready <- rec %>% bake(train_ready)


### Build model

set.seed(42)
mod <- boost_tree(mode="classification", engine="xgboost", trees=300,
                  learn_rate=0.01, sample_size=0.75) %>% fit(category ~ ., data=train_ready)


### Gather test data

food_test <- read_csv("./data/food_test.csv") %>% 
  mutate(ingredients = ifelse(is.na(ingredients), "", ingredients)) # Remove NAs
food_test <- left_join(food_test, food_nutrients, by="idx")
food_test <- left_join(food_test, image_data, by="idx")

test_ready <- full_features(food_test)
test_ready <- rec %>% bake(test_ready)


### Predict on test set

pred <- mod %>% predict(new_data=test_ready) %>% 
        rename(category = .pred_class) %>% 
        mutate(category = case_when(
              category == "cookie" ~ "cookies_biscuits",
              category == "cake" ~ "cakes_cupcakes_snack_cakes",
              category == "savory" ~ "chips_pretzels_snacks",
              category == "seeds" ~ "popcorn_peanuts_seeds_related_snacks",
              TRUE ~ category
              ))
write_csv(cbind(food_test$idx, pred), "model2.csv")

