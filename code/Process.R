# library(R.matlab)
# library(h2o)
# library(hydroGOF)
# # library(MBESS)

if (!require("pacman")) install.packages("pacman")
pacman::p_load(R.matlab, h2o, hydroGOF)

#convert timestamp of Ciao dataset to 11 values
convert_time_stamp = function(time_stamp) 
{
  if(!require(lubridate)) {
    install.packages("lubridate")
  }
  library(lubridate)
  date = as.Date(as.POSIXct(time_stamp, origin="1970-01-01"))
  res = 0
  res = year(date) - 2000
  if (month(date) > 4) {
    res = res + 1
  }
  res
}

# time_point: TRUE if timestamp is already converted to 1..11
# evaluation_method = "division" (use 10 parts for train and 1 for test), "LOO" (leave one out)
# testing_periods: periods will be in test, other will be used for training
# max_mem_size: use to configure h2o server, maybe changed based on your computer
# nthreads: use to configure h2o, -1 means all possible CPU cores
# l1, l2: regularization 
# only use for cross-valdiation
rating_prediction = function(filename = "epinions_rating_with_timestamp.mat", time_point = TRUE, 
                             hiddens = c(200,200),
                             evaluation_method = "division",
                             training_periods = 1:10,
                             testing_periods = c(11),
                             max_mem_size = "8g",
                             nthread = 0,
                             learning_rate=0.001,
                             activation_func="RectifierWithDropout",
                             dropout_ratio = 0.5,
                             l1 = 0.00001,
                             l2 = 1e-5,
                             initial_weight_distribution="Uniform",
                             regression_stop = 0.01,
                             stopping_metric="MSE",
                             stopping_tolerance="0.02",
                             stop_rounds=5,
                             nfold = 5,
                             nb_epoch=50,
                             var_importance = FALSE)
{
  dnn = NULL
  rating = readMat(filename)
  rating = rating$rating
  
  rating = as.data.frame(rating)
  
  colnames(rating) = c("User","Product","Category","Rating","Helpfulnesss","Timestamp")
  
  rating$User = as.factor(rating$User)
  # rating$V2 = as.factor(rating$V2)
  rating$Category = as.factor(rating$Category)
  
  if (time_point == FALSE) {
    rating$Timestamp = sapply(rating$Timestamp, FUN=convert_time_stamp)
  }
  
  if (evaluation_method == "division") {
    train_rating = rating [rating$Timestamp %in% training_periods,]
    test_rating = rating [rating$Timestamp %in% testing_periods,]
    
    # require (plotrix)
    # multhist(list (train_rating$Rating, test_rating$Rating), 
    # breaks=seq(0.5,5.5,by=1),probability=TRUE, ylab="Proportion",
    # xlab = "Rating score of train (black) and test (grey) data set.")
    
    # for 11 time frames in 1 plot
    # for (i in 1:11) {l[[i]] = rating[rating$Timestamp==i,]$Rating}
    # multhist(l, breaks=seq(0.5,5.5,by=1),probability=TRUE, 
    # ylab="Proportion",xlab = "Rating score over 11 time frames")
    
    localH20 = h2o.init(nthreads = nthread, max_mem_size = max_mem_size)
    
    train_rating_h2o = as.h2o (train_rating)
    test_rating_h2o = as.h2o (test_rating)
    
    print ("All data")
    dnn = h2o.deeplearning(x=c(1:3,5:6),y=4, training_frame = train_rating_h2o, 
                           activation = activation_func,
                           validation_frame = test_rating_h2o,
                           hidden = hiddens,
                           epochs = nb_epoch,
                           rate = learning_rate,
                           hidden_dropout_ratios = rep(dropout_ratio, length(hiddens)),
                           l1 = l1,
                           l2 = l2,
                           initial_weight_distribution=initial_weight_distribution,
                           regression_stop = regression_stop,
                           stopping_metric = stopping_metric,
                           stopping_rounds = stop_rounds,
                           variable_importances = var_importance)
    
    rmse_value = sqrt(dnn@model$validation_metrics@metrics$MSE)
    
    # print (ci.rmsea(rmsea = rmse_value, df = nrow(test_rating) - 1, N = nrow(test_rating)))
    
    print (rmse_value) # 1.026661
    
    
    # Product never been rated
    rating_new = test_rating[! (test_rating$Product %in% train_rating$Product 
                                & test_rating$User %in% train_rating$User),]
    h2o_rate_new = as.h2o (rating_new)
    
    print ("Cold start prediction")
    p_new = h2o.predict(dnn, newdata = h2o_rate_new)
    rmse_value = hydroGOF::rmse(as.vector(rating_new$Rating), as.vector(p_new))
    
    # print (ci.rmsea(rmsea = rmse_value, df = nrow(rating_new) - 1, N = nrow(rating_new)))
    print (rmse_value)
    
    # Contain product which are already rated before
    rating_old = test_rating[test_rating$Product %in% train_rating$Product 
                             & test_rating$User %in% train_rating$User,]
    h2o_rate_old = as.h2o (rating_old)
    
    # only new item
    rating_new_item = test_rating[! (test_rating$Product %in% train_rating$Product),]
    print ("Only new items")
    h2o_rate_new_item = as.h2o (rating_new_item)
    p_new = h2o.predict(dnn, newdata = h2o_rate_new_item)
    rmse_value = hydroGOF::rmse(as.vector(rating_new_item$Rating), as.vector(p_new))
    print (rmse_value)
    
    # only new user
    rating_new_user = test_rating[! (test_rating$User %in% train_rating$User),]
    print ("Only new users")
    h2o_rate_new_item = as.h2o (rating_new_user)
    p_new = h2o.predict(dnn, newdata = h2o_rate_new_item)
    rmse_value = hydroGOF::rmse(as.vector(rating_new_user$Rating), as.vector(p_new))
    print (rmse_value)
    
    print ("Existing product and users rating prediction")
    # print (sqrt(dnn@model$validation_metrics@metrics$MSE)) 
    p_old = h2o.predict(dnn, newdata = h2o_rate_old)
    rmse_value = hydroGOF::rmse(as.vector(rating_old$Rating), as.vector(p_old))
    
    # print (ci.rmsea(rmsea = rmse_value, df = nrow(rating_old) - 1, N = nrow(rating_old)))
    print (rmse_value)
    
    png ("plot.png")
    plot (dnn)
    dev.off()
    
    dnn
    # h2o.shutdown(prompt = FALSE)
  }
  
  if (evaluation_method == "LOO") {
    localH20 = h2o.init(nthreads = -1)
    rating_h2o = as.h2o (rating)
    
    dnn = h2o.deeplearning(x=c(1:3,5:6),y=4,
                           training_frame = rating_h2o, nfolds = nfold, hidden = hiddens,
                           activation = activation_func,
                           epochs = nb_epoch,
                           rate = learning_rate,
                           hidden_dropout_ratios = rep(dropout_ratio, length(hiddens)),
                           l1 = l1,
                           l2 = l2,
                           initial_weight_distribution=initial_weight_distribution,
                           regression_stop = regression_stop,
                           stopping_metric = stopping_metric,
                           stopping_rounds = stop_rounds,
                           variable_importances = var_importance)
    
    rmse_value = sqrt(dnn@model$validation_metrics@metrics$MSE)
    
    print (rmse_value)
    
    png ("plot.png")
    plot (dnn)
    dev.off()
    # h2o.shutdown(prompt = FALSE)
    
    dnn
  }
  
  dnn
}

trust_prediction = function (filename = "epinion_trust_with_timestamp.mat")
{
  h2o.init()
  
  trust_data = readMat(filename)
  trust_data = as.data.frame(trust_data$trust)
  colnames (trust_data) = c("Trustor","Trustee","Timestamp")
  
  trust_train = trust_data [trust_data$Timestamp != 11,]
  trust_test = trust_data [trust_data$Timestamp == 11,]
  
  h2o_trust_train = as.h2o (trust_train)
  h2o_trust_test = as.h2o (trust_test)
  
  # dnn = h2o.deeplearning(x=1:2,y=3,training_frame = h2o_trust_train, validation_frame = h2o_trust_test)
  
  rating = readMat("epinions_rating_with_timestamp.mat")
  rating = rating$rating
  
  rating = as.data.frame(rating)
  
  colnames(rating) = c("User","Product","Category","Rating","Helpfulnesss","Timestamp")
  
  rating$User = as.factor(rating$User)
  # rating$V2 = as.factor(rating$V2)
  rating$Category = as.factor(rating$Category)
  
  h2o.shutdown(prompt = TRUE)
}
